#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if !defined(__aarch64__)
#error This probe requires AArch64
#endif

extern void flush_instruction_cache(void *begin, void *end) __asm__("__clear_cache");

int main(void) {
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) return 1;
    void *memory = mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    int (*generated_code)(void) = (int (*)(void))memory;
    for (unsigned int expected = 1; expected <= 128; ++expected) {
        uint32_t instructions[] = {0x52800000u | (expected << 5), 0xd65f03c0u};
        memcpy(memory, instructions, sizeof(instructions));
        flush_instruction_cache(memory, (char *)memory + sizeof(instructions));
        if (mprotect(memory, (size_t)page_size, PROT_READ | PROT_EXEC) != 0) {
            perror("mprotect executable");
            return 1;
        }
        if (generated_code() != (int)expected) {
            fputs("Instruction cache contains stale code\n", stderr);
            return 1;
        }
        if (mprotect(memory, (size_t)page_size, PROT_READ | PROT_WRITE) != 0) {
            perror("mprotect writable");
            return 1;
        }
    }
    flush_instruction_cache(memory, memory);
    if (munmap(memory, (size_t)page_size) != 0) {
        perror("munmap");
        return 1;
    }
    puts("PASS: instruction cache synchronized across 128 code replacements");
    return 0;
}
