#include <Hypervisor/hv.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
static uint64_t next = 0x900000000ull;
static int try(const char *what, void *p, uint64_t gpa, size_t sz, hv_memory_flags_t f, int unmap) {
	hv_return_t r = hv_vm_map(p, gpa, sz, f);
	printf("%-40s gpa=%llx flags=%llx -> 0x%x %s\n", what, (unsigned long long)gpa, (unsigned long long)f, r, r == HV_SUCCESS ? "OK" : "FAIL");
	if (r == HV_SUCCESS && unmap) { r = hv_vm_unmap(gpa, sz); if (r) printf("   unmap 0x%x\n", r); }
	return r;
}
static void *shm(size_t sz, int prot) {
	shm_unlink("/hvmaptest");
	int fd = shm_open("/hvmaptest", O_RDWR | O_CREAT, 0600); ftruncate(fd, sz); shm_unlink("/hvmaptest");
	void *p = mmap(NULL, sz, prot, MAP_SHARED, fd, 0); return p;
}
#define G (next += 0x10000000ull)
int main(void) {
	if (hv_vm_create(HV_VM_DEFAULT)) return 1;
	size_t sz = 64 * 1024; hv_memory_flags_t RWX = 7, RW = 3;
	void *a = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	void *s = shm(sz, PROT_READ | PROT_WRITE); memset(s, 0, sz);
	try("shm RW fresh gpa, RWX", s, G, sz, RWX, 1);
	try("shm RW fresh gpa, RW", s, G, sz, RW, 1);
	try("anon fresh gpa, RWX", a, G, sz, RWX, 1);
	uint64_t g = G;
	try("anon gpa X, RWX (then unmap)", a, g, sz, RWX, 1);
	try("anon again same gpa X", a, g, sz, RWX, 1);
	try("shm same gpa X after unmap", s, g, sz, RW, 1);
	g = G;
	try("shm gpa Y (keep)", s, g, sz, RW, 0);
	try("shm second gpa while mapped (alias)", s, G, sz, RW, 1);
	hv_vm_unmap(g, sz);
	void *s2 = shm(sz, PROT_READ | PROT_WRITE);
	try("shm untouched pages, RW", s2, G, sz, RW, 1);
	void *big = shm(8 << 20, PROT_READ | PROT_WRITE);
	try("shm 8M untouched", big, G, 8 << 20, RW, 1);
	// inside a big container gap like QEMU: map anon 8G-ish neighbours? just low gpa below 4G
	try("shm at 0xC0000000", s, 0xC0000000ull, sz, RW, 1);
	try("shm at 39-bit top", s, 0x7ff0000000ull, sz, RW, 1);
	try("shm at 2^40", s, 0x10000000000ull, sz, RW, 1);
	return 0;
}
