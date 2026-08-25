// SPDX-License-Identifier: GPL-2.0
/*
 * PCAM AES-GCM DMA-BUF bridge.
 *
 * The AXI DMA itself is owned by the in-tree Xilinx DMAengine driver.  This
 * module only imports stable DMA-BUF file descriptors and submits one MM2S and
 * one S2MM transfer as a pair.  Userspace can START, send the previous output
 * buffer, and WAIT, preserving the existing two-buffer pipeline.
 */

#include <linux/completion.h>
#include <linux/dma-buf.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include "pcam_aes_bridge.h"

#define PCAM_AES_DEVICE_NAME "pcam_aes_bridge"
#define PCAM_AES_MAX_IMPORTS  8U
#define PCAM_AES_ALIGNMENT    16U
#define PCAM_AES_MAX_BYTES    0x007fffffU
#define PCAM_AES_WAIT_MS      1000U

struct pcam_aes_bridge {
    struct device *dev;
    struct dma_chan *tx_chan;
    struct dma_chan *rx_chan;
    struct device *dma_dev;
    struct miscdevice miscdev;
    atomic_t opened;
};

struct pcam_aes_mapping {
    struct dma_buf *dmabuf;
    struct dma_buf_attachment *attachment;
    struct sg_table *sgt;
    enum dma_data_direction dma_direction;
    u32 user_direction;
};

struct pcam_aes_file {
    struct pcam_aes_bridge *bridge;
    struct mutex lock;
    struct pcam_aes_mapping mappings[PCAM_AES_MAX_IMPORTS];
    struct completion tx_done;
    struct completion rx_done;
    dma_cookie_t tx_cookie;
    dma_cookie_t rx_cookie;
    bool active;
};

static void pcam_aes_tx_complete(void *argument)
{
    struct pcam_aes_file *context = argument;

    complete(&context->tx_done);
}

static void pcam_aes_rx_complete(void *argument)
{
    struct pcam_aes_file *context = argument;

    complete(&context->rx_done);
}

static void pcam_aes_unmap(struct pcam_aes_mapping *mapping)
{
    if (!mapping->dmabuf)
        return;
    if (mapping->sgt)
        dma_buf_unmap_attachment_unlocked(mapping->attachment,
                                          mapping->sgt,
                                          mapping->dma_direction);
    if (mapping->attachment)
        dma_buf_detach(mapping->dmabuf, mapping->attachment);
    dma_buf_put(mapping->dmabuf);
    memset(mapping, 0, sizeof(*mapping));
}

static void pcam_aes_stop(struct pcam_aes_file *context)
{
    if (!context->active)
        return;
    dmaengine_terminate_sync(context->bridge->tx_chan);
    dmaengine_terminate_sync(context->bridge->rx_chan);
    context->active = false;
}

static int pcam_aes_open(struct inode *inode, struct file *file)
{
    struct miscdevice *miscdev = file->private_data;
    struct pcam_aes_bridge *bridge =
        container_of(miscdev, struct pcam_aes_bridge, miscdev);
    struct pcam_aes_file *context;

    if (atomic_cmpxchg(&bridge->opened, 0, 1) != 0)
        return -EBUSY;

    context = kzalloc(sizeof(*context), GFP_KERNEL);
    if (!context) {
        atomic_set(&bridge->opened, 0);
        return -ENOMEM;
    }
    context->bridge = bridge;
    mutex_init(&context->lock);
    init_completion(&context->tx_done);
    init_completion(&context->rx_done);
    file->private_data = context;
    return 0;
}

static int pcam_aes_release(struct inode *inode, struct file *file)
{
    struct pcam_aes_file *context = file->private_data;
    unsigned int index;

    mutex_lock(&context->lock);
    pcam_aes_stop(context);
    for (index = 0; index < PCAM_AES_MAX_IMPORTS; ++index)
        pcam_aes_unmap(&context->mappings[index]);
    mutex_unlock(&context->lock);
    atomic_set(&context->bridge->opened, 0);
    kfree(context);
    return 0;
}

static long pcam_aes_get_info(void __user *argument)
{
    const struct pcam_aes_info info = {
        .abi_version = PCAM_AES_ABI_VERSION,
        .alignment = PCAM_AES_ALIGNMENT,
        .max_transfer_bytes = PCAM_AES_MAX_BYTES,
    };

    return copy_to_user(argument, &info, sizeof(info)) ? -EFAULT : 0;
}

static long pcam_aes_import(struct pcam_aes_file *context,
                            void __user *argument)
{
    struct pcam_aes_import request;
    struct pcam_aes_mapping *mapping = NULL;
    enum dma_data_direction dma_direction;
    unsigned int index;
    long result = 0;

    if (copy_from_user(&request, argument, sizeof(request)))
        return -EFAULT;
    if (request.direction == PCAM_AES_BUFFER_INPUT)
        dma_direction = DMA_TO_DEVICE;
    else if (request.direction == PCAM_AES_BUFFER_OUTPUT)
        dma_direction = DMA_FROM_DEVICE;
    else
        return -EINVAL;

    mutex_lock(&context->lock);
    if (context->active) {
        result = -EBUSY;
        goto unlock;
    }
    for (index = 0; index < PCAM_AES_MAX_IMPORTS; ++index) {
        if (!context->mappings[index].dmabuf) {
            mapping = &context->mappings[index];
            break;
        }
    }
    if (!mapping) {
        result = -ENOSPC;
        goto unlock;
    }

    mapping->dmabuf = dma_buf_get(request.dmabuf_fd);
    if (IS_ERR(mapping->dmabuf)) {
        result = PTR_ERR(mapping->dmabuf);
        mapping->dmabuf = NULL;
        goto unlock;
    }
    mapping->attachment = dma_buf_attach(mapping->dmabuf,
                                         context->bridge->dma_dev);
    if (IS_ERR(mapping->attachment)) {
        result = PTR_ERR(mapping->attachment);
        mapping->attachment = NULL;
        goto fail_mapping;
    }
    mapping->sgt = dma_buf_map_attachment_unlocked(mapping->attachment,
                                                   dma_direction);
    if (IS_ERR(mapping->sgt)) {
        result = PTR_ERR(mapping->sgt);
        mapping->sgt = NULL;
        goto fail_mapping;
    }
    if (mapping->sgt->nents != 1 ||
        sg_dma_len(mapping->sgt->sgl) < mapping->dmabuf->size) {
        result = -EINVAL;
        goto fail_mapping;
    }
    mapping->dma_direction = dma_direction;
    mapping->user_direction = request.direction;
    request.handle = index + 1U;
    /* Zynq-7000 has no IOMMU, so this DMA address is also the address that
     * the userspace-controlled display VDMA must use.  Older TX userspace
     * ignores this backward-compatible output field. */
    request.reserved = (u32)sg_dma_address(mapping->sgt->sgl);
    if (copy_to_user(argument, &request, sizeof(request))) {
        result = -EFAULT;
        goto fail_mapping;
    }
    goto unlock;

fail_mapping:
    pcam_aes_unmap(mapping);
unlock:
    mutex_unlock(&context->lock);
    return result;
}

static struct pcam_aes_mapping *
pcam_aes_mapping_from_handle(struct pcam_aes_file *context, u32 handle)
{
    if (handle == 0 || handle > PCAM_AES_MAX_IMPORTS)
        return NULL;
    if (!context->mappings[handle - 1U].dmabuf)
        return NULL;
    return &context->mappings[handle - 1U];
}

static long pcam_aes_start(struct pcam_aes_file *context,
                           void __user *argument)
{
    struct pcam_aes_start request;
    struct pcam_aes_mapping *input;
    struct pcam_aes_mapping *output;
    struct dma_async_tx_descriptor *tx_descriptor;
    struct dma_async_tx_descriptor *rx_descriptor;
    unsigned long descriptor_flags = DMA_CTRL_ACK | DMA_PREP_INTERRUPT;
    u32 output_bytes;
    long result = 0;

    if (copy_from_user(&request, argument, sizeof(request)))
        return -EFAULT;
    output_bytes = request.flags ? request.flags : request.transfer_bytes;
    if (!request.transfer_bytes || !output_bytes ||
        request.transfer_bytes > PCAM_AES_MAX_BYTES ||
        output_bytes > PCAM_AES_MAX_BYTES ||
        request.transfer_bytes % PCAM_AES_ALIGNMENT ||
        output_bytes % PCAM_AES_ALIGNMENT)
        return -EINVAL;

    mutex_lock(&context->lock);
    if (context->active) {
        result = -EBUSY;
        goto unlock;
    }
    input = pcam_aes_mapping_from_handle(context, request.input_handle);
    output = pcam_aes_mapping_from_handle(context, request.output_handle);
    if (!input || !output ||
        input->user_direction != PCAM_AES_BUFFER_INPUT ||
        output->user_direction != PCAM_AES_BUFFER_OUTPUT ||
        request.transfer_bytes > input->dmabuf->size ||
        output_bytes > output->dmabuf->size) {
        result = -EINVAL;
        goto unlock;
    }

    /*
     * RX userspace completes DMA_BUF_IOCTL_SYNC(END) before START.  Repeating
     * dma_sync_sgtable_for_device() here walks both 1.84 MiB frame buffers and
     * costs about 24 ms per frame on Zynq-7000.  Ownership is already with the
     * device, so START must only submit the two DMA descriptors.
     */

    rx_descriptor = dmaengine_prep_slave_single(
        context->bridge->rx_chan, sg_dma_address(output->sgt->sgl),
        output_bytes, DMA_DEV_TO_MEM, descriptor_flags);
    tx_descriptor = dmaengine_prep_slave_single(
        context->bridge->tx_chan, sg_dma_address(input->sgt->sgl),
        request.transfer_bytes, DMA_MEM_TO_DEV, descriptor_flags);
    if (!rx_descriptor || !tx_descriptor) {
        result = -EIO;
        goto unlock;
    }
    reinit_completion(&context->tx_done);
    reinit_completion(&context->rx_done);
    rx_descriptor->callback = pcam_aes_rx_complete;
    rx_descriptor->callback_param = context;
    tx_descriptor->callback = pcam_aes_tx_complete;
    tx_descriptor->callback_param = context;
    context->rx_cookie = dmaengine_submit(rx_descriptor);
    if (dma_submit_error(context->rx_cookie)) {
        result = context->rx_cookie;
        goto terminate;
    }
    context->tx_cookie = dmaengine_submit(tx_descriptor);
    if (dma_submit_error(context->tx_cookie)) {
        result = context->tx_cookie;
        goto terminate;
    }

    context->active = true;
    dma_async_issue_pending(context->bridge->rx_chan);
    dma_async_issue_pending(context->bridge->tx_chan);
    goto unlock;

terminate:
    dmaengine_terminate_sync(context->bridge->tx_chan);
    dmaengine_terminate_sync(context->bridge->rx_chan);
unlock:
    mutex_unlock(&context->lock);
    return result;
}

static long pcam_aes_wait(struct pcam_aes_file *context,
                          void __user *argument)
{
    struct pcam_aes_wait request;
    unsigned long timeout;
    long tx_wait;
    long rx_wait;
    long result = 0;

    if (copy_from_user(&request, argument, sizeof(request)))
        return -EFAULT;
    if (!request.timeout_ms)
        request.timeout_ms = PCAM_AES_WAIT_MS;
    timeout = msecs_to_jiffies(request.timeout_ms);

    mutex_lock(&context->lock);
    if (!context->active) {
        result = -EINVAL;
        goto unlock;
    }
    tx_wait = wait_for_completion_interruptible_timeout(&context->tx_done,
                                                         timeout);
    rx_wait = tx_wait > 0 ?
        wait_for_completion_interruptible_timeout(&context->rx_done,
                                                   timeout) : tx_wait;
    request.tx_status = dma_async_is_tx_complete(context->bridge->tx_chan,
                                                  context->tx_cookie,
                                                  NULL, NULL);
    request.rx_status = dma_async_is_tx_complete(context->bridge->rx_chan,
                                                  context->rx_cookie,
                                                  NULL, NULL);
    if (tx_wait <= 0 || rx_wait <= 0 ||
        request.tx_status != DMA_COMPLETE ||
        request.rx_status != DMA_COMPLETE) {
        request.status = tx_wait == 0 || rx_wait == 0 ? -ETIMEDOUT : -EIO;
        dmaengine_terminate_sync(context->bridge->tx_chan);
        dmaengine_terminate_sync(context->bridge->rx_chan);
    } else {
        request.status = 0;
    }
    context->active = false;
    if (copy_to_user(argument, &request, sizeof(request)))
        result = -EFAULT;

unlock:
    mutex_unlock(&context->lock);
    return result;
}

static long pcam_aes_ioctl(struct file *file, unsigned int command,
                           unsigned long argument)
{
    struct pcam_aes_file *context = file->private_data;
    void __user *user_argument = (void __user *)argument;

    switch (command) {
    case PCAM_AES_IOC_GET_INFO:
        return pcam_aes_get_info(user_argument);
    case PCAM_AES_IOC_IMPORT:
        return pcam_aes_import(context, user_argument);
    case PCAM_AES_IOC_START:
        return pcam_aes_start(context, user_argument);
    case PCAM_AES_IOC_WAIT:
        return pcam_aes_wait(context, user_argument);
    default:
        return -ENOTTY;
    }
}

static const struct file_operations pcam_aes_file_operations = {
    .owner = THIS_MODULE,
    .open = pcam_aes_open,
    .release = pcam_aes_release,
    .unlocked_ioctl = pcam_aes_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl = pcam_aes_ioctl,
#endif
};

static int pcam_aes_probe(struct platform_device *pdev)
{
    struct pcam_aes_bridge *bridge;
    int result;

    bridge = devm_kzalloc(&pdev->dev, sizeof(*bridge), GFP_KERNEL);
    if (!bridge)
        return -ENOMEM;
    bridge->dev = &pdev->dev;
    bridge->tx_chan = dma_request_chan(&pdev->dev, "tx");
    if (IS_ERR(bridge->tx_chan))
        return dev_err_probe(&pdev->dev, PTR_ERR(bridge->tx_chan),
                             "failed to request MM2S channel\n");
    bridge->rx_chan = dma_request_chan(&pdev->dev, "rx");
    if (IS_ERR(bridge->rx_chan)) {
        result = dev_err_probe(&pdev->dev, PTR_ERR(bridge->rx_chan),
                               "failed to request S2MM channel\n");
        dma_release_channel(bridge->tx_chan);
        return result;
    }
    bridge->dma_dev = dmaengine_get_dma_device(bridge->tx_chan);
    atomic_set(&bridge->opened, 0);
    bridge->miscdev.minor = MISC_DYNAMIC_MINOR;
    bridge->miscdev.name = PCAM_AES_DEVICE_NAME;
    bridge->miscdev.fops = &pcam_aes_file_operations;
    bridge->miscdev.parent = &pdev->dev;
    result = misc_register(&bridge->miscdev);
    if (result) {
        dma_release_channel(bridge->rx_chan);
        dma_release_channel(bridge->tx_chan);
        return result;
    }
    platform_set_drvdata(pdev, bridge);
    dev_info(&pdev->dev, "DMA-BUF bridge ready on %s\n",
             dev_name(bridge->dma_dev));
    return 0;
}

static void pcam_aes_remove(struct platform_device *pdev)
{
    struct pcam_aes_bridge *bridge = platform_get_drvdata(pdev);

    misc_deregister(&bridge->miscdev);
    dma_release_channel(bridge->rx_chan);
    dma_release_channel(bridge->tx_chan);
}

static const struct of_device_id pcam_aes_of_match[] = {
    { .compatible = "kccistc,pcam-aes-gcm-bridge-1.0" },
    { }
};
MODULE_DEVICE_TABLE(of, pcam_aes_of_match);

static struct platform_driver pcam_aes_driver = {
    .probe = pcam_aes_probe,
    .remove_new = pcam_aes_remove,
    .driver = {
        .name = PCAM_AES_DEVICE_NAME,
        .of_match_table = pcam_aes_of_match,
    },
};
module_platform_driver(pcam_aes_driver);

MODULE_IMPORT_NS(DMA_BUF);
MODULE_AUTHOR("PCAM AES-GCM project");
MODULE_DESCRIPTION("DMA-BUF to Xilinx AXI DMA bridge for PCAM AES-GCM");
MODULE_LICENSE("GPL");
