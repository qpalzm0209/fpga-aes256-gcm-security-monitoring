#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef __ARM_NR_cacheflush
#define __ARM_NR_cacheflush 0x0f0002
#endif

static uint64_t monotonic_ns(void)
{
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000000000ULL + value.tv_nsec;
}

static int flush_user_cache(void *address, size_t length)
{
    return (int)syscall(__ARM_NR_cacheflush, address,
                        (uint8_t *)address + length, 0);
}

static int run_mode(unsigned long physical, size_t length, int synchronous)
{
    const int iterations = 32;
    int flags = O_RDWR | O_CLOEXEC | (synchronous ? O_SYNC : 0);
    int fd = open("/dev/mem", flags);
    uint8_t *mapping;
    uint8_t *copy;
    uint64_t started, elapsed;
    uint64_t write_elapsed;
    unsigned int checksum = 0;
    int cache_result = 0;
    int saved_errno = 0;

    if (fd < 0) {
        perror("open /dev/mem");
        return -1;
    }
    mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED,
                   fd, (off_t)physical);
    if (mapping == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }
    if (posix_memalign((void **)&copy, 64, length) != 0) {
        fprintf(stderr, "allocation failed\n");
        munmap(mapping, length);
        close(fd);
        return -1;
    }

    cache_result = flush_user_cache(mapping, length);
    saved_errno = errno;
    started = monotonic_ns();
    for (int iteration = 0; iteration < iterations; ++iteration) {
        if (!synchronous)
            (void)flush_user_cache(mapping, length);
        memcpy(copy, mapping, length);
        checksum += copy[(size_t)iteration * 4093U % length];
    }
    elapsed = monotonic_ns() - started;

    memset(copy, 0xa5, length);
    started = monotonic_ns();
    for (int iteration = 0; iteration < iterations; ++iteration) {
        memcpy(mapping, copy, length);
        if (!synchronous)
            (void)flush_user_cache(mapping, length);
    }
    write_elapsed = monotonic_ns() - started;

    printf("mode=%s length=%zu iterations=%d avg_ms=%.3f throughput=%.1fMiB/s cacheflush=%d errno=%d checksum=%u\n",
           synchronous ? "O_SYNC" : "cached", length, iterations,
           elapsed / 1000000.0 / iterations,
           ((double)length * iterations / (1024.0 * 1024.0)) /
               (elapsed / 1000000000.0),
           cache_result, saved_errno, checksum);
    printf("mode=%s write_avg_ms=%.3f write_throughput=%.1fMiB/s\n",
           synchronous ? "O_SYNC" : "cached",
           write_elapsed / 1000000.0 / iterations,
           ((double)length * iterations / (1024.0 * 1024.0)) /
               (write_elapsed / 1000000000.0));

    free(copy);
    munmap(mapping, length);
    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    unsigned long physical = argc > 1 ? strtoul(argv[1], NULL, 0) : 0x18200000UL;
    size_t length = argc > 2 ? strtoul(argv[2], NULL, 0) : 1843200U;

    if (run_mode(physical, length, 1) < 0)
        return EXIT_FAILURE;
    if (run_mode(physical, length, 0) < 0)
        return EXIT_FAILURE;
    return EXIT_SUCCESS;
}
