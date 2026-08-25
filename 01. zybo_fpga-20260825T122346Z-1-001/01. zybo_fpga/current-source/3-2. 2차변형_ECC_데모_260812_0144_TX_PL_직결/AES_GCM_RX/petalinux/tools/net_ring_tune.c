#include <errno.h>
#include <linux/ethtool.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *name = argc > 1 ? argv[1] : "enx000a35001e53";
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr = {0};
    struct ethtool_ringparam ring = {0};

    if (fd < 0) {
        perror("socket");
        return 1;
    }
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
    ring.cmd = ETHTOOL_GRINGPARAM;
    ifr.ifr_data = (void *)&ring;
    if (ioctl(fd, SIOCETHTOOL, &ifr) < 0) {
        perror("ETHTOOL_GRINGPARAM");
        close(fd);
        return 1;
    }
    printf("ring rx=%u/%u rx_mini=%u/%u rx_jumbo=%u/%u tx=%u/%u\n",
           ring.rx_pending, ring.rx_max_pending,
           ring.rx_mini_pending, ring.rx_mini_max_pending,
           ring.rx_jumbo_pending, ring.rx_jumbo_max_pending,
           ring.tx_pending, ring.tx_max_pending);

    if (argc > 2) {
        unsigned long requested = strtoul(argv[2], NULL, 0);
        if (requested == 0 || requested > ring.rx_max_pending) {
            fprintf(stderr, "invalid RX ring size %lu (maximum %u)\n",
                    requested, ring.rx_max_pending);
            close(fd);
            return 1;
        }
        ring.cmd = ETHTOOL_SRINGPARAM;
        ring.rx_pending = (unsigned int)requested;
        if (ioctl(fd, SIOCETHTOOL, &ifr) < 0) {
            perror("ETHTOOL_SRINGPARAM");
            close(fd);
            return 1;
        }
        printf("RX ring requested=%lu\n", requested);
    }

    {
        struct ethtool_coalesce coalesce = {0};
        coalesce.cmd = ETHTOOL_GCOALESCE;
        ifr.ifr_data = (void *)&coalesce;
        if (ioctl(fd, SIOCETHTOOL, &ifr) < 0) {
            fprintf(stderr, "ETHTOOL_GCOALESCE: %s\n", strerror(errno));
        } else {
            printf("coalesce rx_usecs=%u rx_frames=%u adaptive_rx=%u "
                   "tx_usecs=%u tx_frames=%u\n",
                   coalesce.rx_coalesce_usecs,
                   coalesce.rx_max_coalesced_frames,
                   coalesce.use_adaptive_rx_coalesce,
                   coalesce.tx_coalesce_usecs,
                   coalesce.tx_max_coalesced_frames);
            if (argc > 4) {
                coalesce.cmd = ETHTOOL_SCOALESCE;
                coalesce.rx_coalesce_usecs =
                    (unsigned int)strtoul(argv[3], NULL, 0);
                coalesce.rx_max_coalesced_frames =
                    (unsigned int)strtoul(argv[4], NULL, 0);
                coalesce.use_adaptive_rx_coalesce = 0U;
                if (ioctl(fd, SIOCETHTOOL, &ifr) < 0) {
                    fprintf(stderr, "ETHTOOL_SCOALESCE: %s\n",
                            strerror(errno));
                    close(fd);
                    return 1;
                }
                printf("RX coalesce requested usecs=%s frames=%s\n",
                       argv[3], argv[4]);
            }
        }
    }

    close(fd);
    return 0;
}
