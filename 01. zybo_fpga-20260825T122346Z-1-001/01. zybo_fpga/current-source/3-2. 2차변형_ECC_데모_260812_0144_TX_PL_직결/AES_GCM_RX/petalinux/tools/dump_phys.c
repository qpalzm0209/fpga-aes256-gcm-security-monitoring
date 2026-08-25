#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    unsigned long address;
    size_t length;
    int mem_fd = -1, output_fd = -1;
    uint8_t *mapping = MAP_FAILED;
    size_t written = 0;

    if (argc != 4) {
        fprintf(stderr, "usage: %s PHYS LENGTH OUTPUT\n", argv[0]);
        return 1;
    }
    address = strtoul(argv[1], NULL, 0);
    length = (size_t)strtoul(argv[2], NULL, 0);
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (mem_fd < 0) {
        perror("open /dev/mem");
        return 1;
    }
    mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED,
                   mem_fd, (off_t)address);
    if (mapping == MAP_FAILED) {
        perror("mmap");
        close(mem_fd);
        return 1;
    }
    output_fd = open(argv[3], O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (output_fd < 0) {
        perror("open output");
        munmap(mapping, length);
        close(mem_fd);
        return 1;
    }
    while (written < length) {
        ssize_t result = write(output_fd, mapping + written,
                               length - written);
        if (result < 0 && errno == EINTR)
            continue;
        if (result <= 0) {
            perror("write");
            break;
        }
        written += (size_t)result;
    }
    close(output_fd);
    munmap(mapping, length);
    close(mem_fd);
    return written == length ? 0 : 1;
}
