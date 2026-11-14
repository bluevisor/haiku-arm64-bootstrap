// hvfix: lets QEMU on Intel Macs map non-executable host memory (virtio-gpu
// host blobs, which are POSIX shared memory) into the guest.
//
// QEMU's hvf accelerator maps every RAM region with HV_MEMORY_EXEC. Intel
// Hypervisor.framework fails hv_vm_map() with HV_ERROR when the host mapping's
// maximum protection has no execute right, as shared memory's never does, and
// QEMU then aborts (assert_hvf_ok). A failed map also leaves that guest range
// unusable, so retrying isn't enough: look at the host region first and drop
// the execute flag when it can't be granted. Guest RAM (anonymous memory)
// keeps it.
//
// Loaded by QEMULauncher through an added LC_LOAD_DYLIB; dyld interposing then
// covers the QEMU framework it dlopens.
//
// It also makes QEMU's child, QEMURenderServer, load libmtlfix.dylib (see
// mtlfix.m) when that sits next to this library: the render server is a
// stock binary, so the way in is DYLD_INSERT_LIBRARIES in the environment it
// inherits (its entitlements must allow dyld environment variables).
#include <Hypervisor/hv.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void
hvfix_insert_mtlfix(void)
{
	char exe[PATH_MAX], real[PATH_MAX], lib[PATH_MAX];
	uint32_t size = sizeof(exe);
	if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, real) == NULL)
		return;
	snprintf(lib, sizeof(lib), "%s/libmtlfix.dylib", dirname(real));
	if (access(lib, R_OK) == 0)
		setenv("DYLD_INSERT_LIBRARIES", lib, 1);
}

static hv_return_t
hvfix_vm_map(hv_uvaddr_t uva, hv_gpaddr_t gpa, size_t size, hv_memory_flags_t flags)
{
	if (flags & HV_MEMORY_EXEC) {
		mach_vm_address_t address = (mach_vm_address_t)uva;
		mach_vm_size_t regionSize = 0;
		vm_region_basic_info_data_64_t info;
		mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
		mach_port_t object = MACH_PORT_NULL;
		if (mach_vm_region(mach_task_self(), &address, &regionSize,
				VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count,
				&object) == KERN_SUCCESS
			&& address <= (mach_vm_address_t)uva
			&& (info.max_protection & VM_PROT_EXECUTE) == 0) {
			static int logged;
			if (!logged) {
				logged = 1;
				fprintf(stderr, "hvfix: mapping non-executable host memory "
					"without HV_MEMORY_EXEC (gpa 0x%llx, 0x%zx bytes)\n",
					(unsigned long long)gpa, size);
			}
			flags &= ~(hv_memory_flags_t)HV_MEMORY_EXEC;
		}
		if (object != MACH_PORT_NULL)
			mach_port_deallocate(mach_task_self(), object);
	}
	return hv_vm_map(uva, gpa, size, flags);
}

__attribute__((used)) static struct { const void *replacement, *original; }
	hvfix_interpose[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)hvfix_vm_map, (const void *)hv_vm_map },
};
