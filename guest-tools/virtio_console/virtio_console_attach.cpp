/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */

/*!	Attaches virtio_pci to the virtio console PCI function.

	The device manager only probes on-demand PCI devices for a fixed list of
	classes (disk, net, graphics, audio, input, ...). A virtio console is a
	"simple communications" device, so virtio_pci never gets attached to it
	and the virtio_console driver never sees it. Opening
	/dev/misc/virtio_console_attach registers virtio_pci on that PCI node,
	which runs the normal registration chain: virtio bus -> virtio device ->
	virtio_console, which then publishes /dev/ports/virtio/<port name>.

	A kernel fix would make device_node::Probe() match "ports" against
	PCI_simple_communications; this legacy driver avoids a kernel rebuild.
*/


#include <Drivers.h>
#include <KernelExport.h>
#include <PCI.h>
#include <device_manager.h>
#include <lock.h>
#include <util/AutoLock.h>

#include <string.h>


#define VIRTIO_PCI_VENDOR_ID		0x1af4
#define VIRTIO_CONSOLE_LEGACY_ID	0x1003
#define VIRTIO_CONSOLE_MODERN_ID	0x1043
#define VIRTIO_PCI_DRIVER_MODULE	"busses/virtio/virtio_pci/driver_v1"
#define DEVICE_NAME					"misc/virtio_console_attach"

int32 api_version = B_CUR_DRIVER_API_VERSION;

static device_manager_info* sDeviceManager;
static mutex sLock = MUTEX_INITIALIZER("virtio_console_attach");


static status_t
attach_one(uint16 deviceID)
{
	device_attr attrs[] = {
		{ B_DEVICE_BUS, B_STRING_TYPE, { .string = "pci" }},
		{ B_DEVICE_VENDOR_ID, B_UINT16_TYPE, { .ui16 = VIRTIO_PCI_VENDOR_ID }},
		{ B_DEVICE_ID, B_UINT16_TYPE, { .ui16 = deviceID }},
		{ NULL }
	};

	device_node* pciNode = NULL;
	status_t result = B_ENTRY_NOT_FOUND;
	while (sDeviceManager->find_child_node(sDeviceManager->get_root_node(),
			attrs, &pciNode) == B_OK) {
		// an empty list matches any child (NULL matches none)
		device_attr any[] = { { NULL } };
		device_node* child = NULL;
		if (sDeviceManager->get_next_child_node(pciNode, any, &child)
				== B_OK) {
			// something already drives it
			sDeviceManager->put_node(child);
			result = B_OK;
			continue;
		}

		driver_module_info* driver;
		if (get_module(VIRTIO_PCI_DRIVER_MODULE, (module_info**)&driver)
				!= B_OK) {
			dprintf("virtio_console_attach: no %s\n", VIRTIO_PCI_DRIVER_MODULE);
			sDeviceManager->put_node(pciNode);
			return B_ERROR;
		}

		if (driver->supports_device(pciNode) > 0.0f) {
			result = driver->register_device(pciNode);
			dprintf("virtio_console_attach: registered virtio_pci on console "
				"%04x: %s\n", deviceID, strerror(result));
		}
		put_module(VIRTIO_PCI_DRIVER_MODULE);
	}
	return result;
}


static status_t
attach_consoles()
{
	MutexLocker locker(sLock);
	status_t legacy = attach_one(VIRTIO_CONSOLE_LEGACY_ID);
	status_t modern = attach_one(VIRTIO_CONSOLE_MODERN_ID);
	return legacy == B_OK || modern == B_OK ? B_OK : B_ENTRY_NOT_FOUND;
}


//	#pragma mark - device hooks


static status_t
attach_open(const char* name, uint32 flags, void** cookie)
{
	*cookie = NULL;
	return attach_consoles();
}


static status_t
attach_close(void* cookie)
{
	return B_OK;
}


static status_t
attach_free(void* cookie)
{
	return B_OK;
}


static status_t
attach_control(void* cookie, uint32 op, void* buffer, size_t length)
{
	return B_DEV_INVALID_IOCTL;
}


static status_t
attach_read(void* cookie, off_t position, void* buffer, size_t* _length)
{
	*_length = 0;
	return B_OK;
}


static status_t
attach_write(void* cookie, off_t position, const void* buffer,
	size_t* _length)
{
	*_length = 0;
	return B_NOT_ALLOWED;
}


//	#pragma mark - driver API


status_t
init_hardware()
{
	return B_OK;
}


status_t
init_driver()
{
	return get_module(B_DEVICE_MANAGER_MODULE_NAME,
		(module_info**)&sDeviceManager);
}


void
uninit_driver()
{
	put_module(B_DEVICE_MANAGER_MODULE_NAME);
}


const char**
publish_devices()
{
	static const char* devices[] = { DEVICE_NAME, NULL };
	return devices;
}


device_hooks*
find_device(const char* name)
{
	static device_hooks hooks = {
		attach_open,
		attach_close,
		attach_free,
		attach_control,
		attach_read,
		attach_write,
	};
	return &hooks;
}
