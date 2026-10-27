/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */

/*!	VirtIO console driver (multiport, a.k.a. virtio-serial).

	Each named host port (for example "com.redhat.spice.0" for the SPICE
	agent) is published as /dev/ports/virtio/<name>, and every port also as
	/dev/ports/virtio/vport<n>. Opening a port tells the host the guest side is
	connected; the last close disconnects it again.

	Haiku's virtio bus allows at most 8 virtqueues per device, so only ports
	0-2 can be used (queues 0/1: port 0, 2/3: control, 4/5: port 1,
	6/7: port 2).
*/


#include <virtio.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <new>

#include <KernelExport.h>
#include <kernel.h>
#include <condition_variable.h>
#include <lock.h>
#include <util/AutoLock.h>


//#define TRACE_VIRTIO_CONSOLE
#ifdef TRACE_VIRTIO_CONSOLE
#	define TRACE(x...) dprintf("virtio_console: " x)
#else
#	define TRACE(x...) ;
#endif
#define ERROR(x...)			dprintf("virtio_console: " x)

#define VIRTIO_CONSOLE_DRIVER_MODULE_NAME "drivers/ports/virtio_console/driver_v1"
#define VIRTIO_CONSOLE_DEVICE_MODULE_NAME "drivers/ports/virtio_console/device_v1"
#define VIRTIO_CONSOLE_DEVICE_DIR "ports/virtio"

#define VIRTIO_CONSOLE_F_SIZE		(1 << 0)
#define VIRTIO_CONSOLE_F_MULTIPORT	(1 << 1)

// control events
#define VIRTIO_CONSOLE_DEVICE_READY		0
#define VIRTIO_CONSOLE_DEVICE_ADD		1
#define VIRTIO_CONSOLE_DEVICE_REMOVE	2
#define VIRTIO_CONSOLE_PORT_READY		3
#define VIRTIO_CONSOLE_CONSOLE_PORT		4
#define VIRTIO_CONSOLE_RESIZE			5
#define VIRTIO_CONSOLE_PORT_OPEN		6
#define VIRTIO_CONSOLE_PORT_NAME		7

struct virtio_console_config {
	uint16	cols;
	uint16	rows;
	uint32	max_nr_ports;
	uint32	emerg_wr;
} _PACKED;

struct virtio_console_control {
	uint32	id;
	uint16	event;
	uint16	value;
} _PACKED;


#define MAX_PORTS			3
#define MAX_QUEUES			(2 + 2 * MAX_PORTS)
#define BUFFER_SIZE			4096
#define RX_BUFFERS			8
#define CONTROL_RX_BUFFERS	8
#define NAME_WAIT_TIMEOUT	2000000

// buffer layout in the DMA area
#define CONTROL_RX_INDEX	0
#define CONTROL_TX_INDEX	(CONTROL_RX_INDEX + CONTROL_RX_BUFFERS)
#define PORT_INDEX(port)	(CONTROL_TX_INDEX + 1 + (port) * (RX_BUFFERS + 1))
#define BUFFER_COUNT		PORT_INDEX(MAX_PORTS)


struct ConsoleDevice;

struct ConsolePort {
	int32				id;
	bool				present;
	bool				hostOpen;
	bool				usable;
	int32				openCount;
	char				name[B_FILE_NAME_LENGTH];

	::virtio_queue		rxQueue;
	::virtio_queue		txQueue;

	mutex				writeLock;
	mutex				readLock;

	// filled RX buffers, oldest first; touched under ConsoleDevice::lock
	int32				ready[RX_BUFFERS];
	uint32				readyLength[RX_BUFFERS];
	int32				readyHead;
	int32				readyCount;
	uint32				readOffset;
	ConditionVariable	readCondition;
};

struct ConsoleDevice {
	device_node*		node;
	::virtio_device		virtioDevice;
	virtio_device_interface* virtio;
	uint64				features;

	uint32				portCount;
	ConsolePort			ports[MAX_PORTS];
	::virtio_queue		controlRxQueue;
	::virtio_queue		controlTxQueue;
	mutex				controlTxLock;

	area_id				bufferArea;
	uint8*				buffers;
	phys_addr_t			buffersPhysical;

	spinlock			lock;
	ConditionVariable	namesCondition;

	sem_id				workSem;
	thread_id			workThread;
	bool				workRunning;
	bool				queuesAllocated;
	bool				interruptsSetUp;
};

struct ConsoleHandle {
	ConsoleDevice*		device;
	ConsolePort*		port;
};


static device_manager_info* sDeviceManager;


static inline uint8*
buffer_at(ConsoleDevice* device, int32 index)
{
	return device->buffers + (size_t)index * BUFFER_SIZE;
}


static inline physical_entry
buffer_entry(ConsoleDevice* device, int32 index, size_t size = BUFFER_SIZE)
{
	physical_entry entry;
	entry.address = device->buffersPhysical + (phys_addr_t)index * BUFFER_SIZE;
	entry.size = size;
	return entry;
}


static void
queue_rx_buffer(ConsoleDevice* device, ::virtio_queue queue, int32 index)
{
	physical_entry entry = buffer_entry(device, index);
	device->virtio->queue_request(queue, NULL, &entry,
		(void*)(addr_t)(index + 1));
}


/*!	Sends one request and polls for its completion; the host consumes TX
	buffers quickly, so this never waits long.
*/
static status_t
send_and_wait(ConsoleDevice* device, ::virtio_queue queue, int32 index,
	size_t size)
{
	physical_entry entry = buffer_entry(device, index, size);
	status_t status = device->virtio->queue_request(queue, &entry, NULL,
		(void*)(addr_t)(index + 1));
	if (status != B_OK)
		return status;

	bigtime_t deadline = system_time() + 2000000;
	void* cookie;
	while (!device->virtio->queue_dequeue(queue, &cookie, NULL)) {
		if (system_time() > deadline) {
			ERROR("TX timed out\n");
			return B_TIMED_OUT;
		}
		snooze(20);
	}
	return B_OK;
}


static status_t
send_control(ConsoleDevice* device, uint32 id, uint16 event, uint16 value)
{
	MutexLocker locker(device->controlTxLock);

	virtio_console_control* control
		= (virtio_console_control*)buffer_at(device, CONTROL_TX_INDEX);
	control->id = id;
	control->event = event;
	control->value = value;
	TRACE("send control id %" B_PRIu32 " event %u value %u\n", id, event,
		value);
	return send_and_wait(device, device->controlTxQueue, CONTROL_TX_INDEX,
		sizeof(virtio_console_control));
}


static void
handle_control(ConsoleDevice* device, const uint8* data, uint32 length)
{
	if (length < sizeof(virtio_console_control))
		return;

	const virtio_console_control* control
		= (const virtio_console_control*)data;
	TRACE("control id %" B_PRIu32 " event %u value %u\n", control->id,
		control->event, control->value);

	if (control->id >= device->portCount) {
		if (control->event == VIRTIO_CONSOLE_DEVICE_ADD) {
			ERROR("port %" B_PRIu32 " is beyond the %d supported ports\n",
				control->id, MAX_PORTS);
			send_control(device, control->id, VIRTIO_CONSOLE_PORT_READY, 0);
		}
		return;
	}

	ConsolePort& port = device->ports[control->id];
	switch (control->event) {
		case VIRTIO_CONSOLE_DEVICE_ADD:
			port.present = true;
			send_control(device, port.id, VIRTIO_CONSOLE_PORT_READY, 1);
			break;

		case VIRTIO_CONSOLE_DEVICE_REMOVE:
			port.present = false;
			port.hostOpen = false;
			port.readCondition.NotifyAll(B_DEV_NOT_READY);
			break;

		case VIRTIO_CONSOLE_CONSOLE_PORT:
			// We do not provide a console; just keep the port usable.
			break;

		case VIRTIO_CONSOLE_PORT_OPEN:
			port.hostOpen = control->value != 0;
			break;

		case VIRTIO_CONSOLE_PORT_NAME:
		{
			uint32 nameLength = length - sizeof(virtio_console_control);
			if (nameLength >= sizeof(port.name))
				nameLength = sizeof(port.name) - 1;
			memcpy(port.name, data + sizeof(virtio_console_control),
				nameLength);
			port.name[nameLength] = '\0';
			// names never contain a slash in practice, but devfs would
			// treat one as a directory
			for (char* c = port.name; *c != '\0'; c++) {
				if (*c == '/')
					*c = '_';
			}
			dprintf("virtio_console: port %" B_PRId32 " is \"%s\"\n", port.id,
				port.name);
			device->namesCondition.NotifyAll();
			break;
		}

		case VIRTIO_CONSOLE_RESIZE:
		default:
			break;
	}
}


static int32
work_thread(void* data)
{
	ConsoleDevice* device = (ConsoleDevice*)data;

	while (device->workRunning) {
		acquire_sem_etc(device->workSem, 1, B_RELATIVE_TIMEOUT, 500000);

		void* cookie;
		uint32 length;
		while (device->virtio->queue_dequeue(device->controlRxQueue, &cookie,
				&length)) {
			int32 index = (int32)(addr_t)cookie - 1;
			handle_control(device, buffer_at(device, index), length);
			queue_rx_buffer(device, device->controlRxQueue, index);
		}

		for (uint32 i = 0; i < device->portCount; i++) {
			ConsolePort& port = device->ports[i];
			if (!port.usable)
				continue;
			while (device->virtio->queue_dequeue(port.rxQueue, &cookie,
					&length)) {
				int32 index = (int32)(addr_t)cookie - 1;
				InterruptsSpinLocker locker(device->lock);
				int32 slot = (port.readyHead + port.readyCount) % RX_BUFFERS;
				port.ready[slot] = index;
				port.readyLength[slot] = length;
				port.readyCount++;
				port.readCondition.NotifyAll();
			}
		}
	}
	return 0;
}


static void
queue_interrupt(void* driverCookie, void* cookie)
{
	ConsoleDevice* device = (ConsoleDevice*)cookie;
	release_sem_etc(device->workSem, 1, B_DO_NOT_RESCHEDULE);
}


static ConsolePort*
port_for_path(ConsoleDevice* device, const char* path)
{
	const char* leaf = strrchr(path, '/');
	leaf = leaf != NULL ? leaf + 1 : path;

	for (uint32 i = 0; i < device->portCount; i++) {
		ConsolePort& port = device->ports[i];
		char numbered[16];
		snprintf(numbered, sizeof(numbered), "vport%" B_PRId32, port.id);
		if (strcmp(leaf, numbered) == 0
			|| (port.name[0] != '\0' && strcmp(leaf, port.name) == 0)) {
			return &port;
		}
	}
	return NULL;
}


//	#pragma mark - hardware setup


static status_t
init_hardware(ConsoleDevice* device)
{
	device_node* parent = sDeviceManager->get_parent_node(device->node);
	sDeviceManager->get_driver(parent, (driver_module_info**)&device->virtio,
		(void**)&device->virtioDevice);
	sDeviceManager->put_node(parent);

	status_t status = device->virtio->negotiate_features(device->virtioDevice,
		VIRTIO_CONSOLE_F_MULTIPORT, &device->features, NULL);
	if (status != B_OK)
		return status;
	TRACE("negotiated features %#" B_PRIx64 "\n", device->features);

	uint32 maxPorts = 1;
	if ((device->features & VIRTIO_CONSOLE_F_MULTIPORT) != 0) {
		device->virtio->read_device_config(device->virtioDevice,
			offsetof(virtio_console_config, max_nr_ports), &maxPorts,
			sizeof(maxPorts));
	}
	if ((device->features & VIRTIO_CONSOLE_F_MULTIPORT) == 0) {
		// Also what a transitional (legacy) device looks like: Haiku arm64
		// reads its I/O BAR as zeros. Start QEMU with
		// -global virtio-serial-pci.disable-legacy=on.
		ERROR("host has no multiport support\n");
		return B_NOT_SUPPORTED;
	}
	device->portCount = min_c(maxPorts, (uint32)MAX_PORTS);
	TRACE("host offers %" B_PRIu32 " ports, using %" B_PRIu32 "\n", maxPorts,
		device->portCount);

	size_t areaSize = ROUNDUP((size_t)BUFFER_COUNT * BUFFER_SIZE, B_PAGE_SIZE);
	device->bufferArea = create_area("virtio_console buffers",
		(void**)&device->buffers, B_ANY_KERNEL_ADDRESS, areaSize,
		B_CONTIGUOUS, B_KERNEL_READ_AREA | B_KERNEL_WRITE_AREA);
	if (device->bufferArea < B_OK)
		return device->bufferArea;
	physical_entry entry;
	get_memory_map(device->buffers, B_PAGE_SIZE, &entry, 1);
	device->buffersPhysical = entry.address;

	uint32 queueCount = 2 + 2 * device->portCount;
	::virtio_queue queues[MAX_QUEUES];
	status = device->virtio->alloc_queues(device->virtioDevice, queueCount,
		queues, NULL);
	if (status != B_OK) {
		ERROR("queue allocation failed (%s)\n", strerror(status));
		return status;
	}
	device->queuesAllocated = true;

	device->controlRxQueue = queues[2];
	device->controlTxQueue = queues[3];
	for (uint32 i = 0; i < device->portCount; i++) {
		ConsolePort& port = device->ports[i];
		uint32 rx = i == 0 ? 0 : 2 + 2 * i;
		port.rxQueue = queues[rx];
		port.txQueue = queues[rx + 1];
	}

	device->workSem = create_sem(0, "virtio_console work");
	device->workRunning = true;
	device->workThread = spawn_kernel_thread(work_thread, "virtio_console",
		B_NORMAL_PRIORITY + 5, device);
	if (device->workThread < B_OK)
		return device->workThread;

	status = device->virtio->setup_interrupt(device->virtioDevice, NULL,
		device);
	if (status != B_OK)
		return status;
	device->interruptsSetUp = true;

	device->virtio->queue_setup_interrupt(device->controlRxQueue,
		queue_interrupt, device);
	for (uint32 i = 0; i < device->portCount; i++) {
		device->virtio->queue_setup_interrupt(device->ports[i].rxQueue,
			queue_interrupt, device);
	}

	for (int32 i = 0; i < CONTROL_RX_BUFFERS; i++)
		queue_rx_buffer(device, device->controlRxQueue, CONTROL_RX_INDEX + i);
	for (uint32 i = 0; i < device->portCount; i++) {
		ConsolePort& port = device->ports[i];
		for (int32 j = 0; j < RX_BUFFERS; j++)
			queue_rx_buffer(device, port.rxQueue, PORT_INDEX(i) + 1 + j);
		port.usable = true;
	}

	resume_thread(device->workThread);

	return send_control(device, 0xffffffff, VIRTIO_CONSOLE_DEVICE_READY, 1);
}


//	#pragma mark - device module API


static status_t
virtio_console_init_device(void* _info, void** _cookie)
{
	*_cookie = _info;
	return B_OK;
}


static void
virtio_console_uninit_device(void* _cookie)
{
}


static status_t
virtio_console_open(void* _info, const char* path, int openMode,
	void** _cookie)
{
	ConsoleDevice* device = (ConsoleDevice*)_info;
	ConsolePort* port = port_for_path(device, path);
	if (port == NULL || !port->usable)
		return B_ENTRY_NOT_FOUND;
	if (!port->present)
		return B_DEV_NOT_READY;

	// One reader per port: a second one would block uninterruptibly on
	// readLock behind the first, and the host protocol is a single stream.
	if (atomic_test_and_set(&port->openCount, 1, 0) != 0)
		return B_BUSY;

	ConsoleHandle* handle = new(std::nothrow) ConsoleHandle;
	if (handle == NULL) {
		atomic_set(&port->openCount, 0);
		return B_NO_MEMORY;
	}
	handle->device = device;
	handle->port = port;

	{
		// drop whatever the host sent while nobody listened
		InterruptsSpinLocker locker(device->lock);
		while (port->readyCount > 0) {
			int32 index = port->ready[port->readyHead];
			port->readyHead = (port->readyHead + 1) % RX_BUFFERS;
			port->readyCount--;
			locker.Unlock();
			queue_rx_buffer(device, port->rxQueue, index);
			locker.Lock();
		}
		port->readOffset = 0;
		locker.Unlock();
		send_control(device, port->id, VIRTIO_CONSOLE_PORT_OPEN, 1);
	}

	*_cookie = handle;
	return B_OK;
}


static status_t
virtio_console_close(void* cookie)
{
	ConsoleHandle* handle = (ConsoleHandle*)cookie;
	handle->port->readCondition.NotifyAll(B_FILE_ERROR);
	return B_OK;
}


static status_t
virtio_console_free(void* cookie)
{
	ConsoleHandle* handle = (ConsoleHandle*)cookie;
	ConsolePort* port = handle->port;
	if (atomic_add(&port->openCount, -1) == 1 && port->present)
		send_control(handle->device, port->id, VIRTIO_CONSOLE_PORT_OPEN, 0);
	delete handle;
	return B_OK;
}


static status_t
virtio_console_read(void* cookie, off_t pos, void* buffer, size_t* _length)
{
	ConsoleHandle* handle = (ConsoleHandle*)cookie;
	ConsoleDevice* device = handle->device;
	ConsolePort* port = handle->port;

	MutexLocker readLocker(port->readLock);
	InterruptsSpinLocker locker(device->lock);

	while (port->readyCount == 0) {
		if (!port->present) {
			*_length = 0;
			return B_DEV_NOT_READY;
		}
		ConditionVariableEntry entry;
		port->readCondition.Add(&entry);
		locker.Unlock();
		status_t status = entry.Wait(B_CAN_INTERRUPT);
		locker.Lock();
		if (status != B_OK && port->readyCount == 0) {
			*_length = 0;
			return status;
		}
	}

	int32 index = port->ready[port->readyHead];
	uint32 available = port->readyLength[port->readyHead] - port->readOffset;
	size_t length = min_c(*_length, (size_t)available);
	uint32 offset = port->readOffset;
	locker.Unlock();

	status_t status = user_memcpy(buffer, buffer_at(device, index) + offset,
		length);
	if (status != B_OK) {
		*_length = 0;
		return status;
	}

	locker.Lock();
	port->readOffset += length;
	bool consumed = port->readOffset >= port->readyLength[port->readyHead];
	if (consumed) {
		port->readyHead = (port->readyHead + 1) % RX_BUFFERS;
		port->readyCount--;
		port->readOffset = 0;
	}
	locker.Unlock();

	if (consumed)
		queue_rx_buffer(device, port->rxQueue, index);

	*_length = length;
	return B_OK;
}


static status_t
virtio_console_write(void* cookie, off_t pos, const void* buffer,
	size_t* _length)
{
	ConsoleHandle* handle = (ConsoleHandle*)cookie;
	ConsoleDevice* device = handle->device;
	ConsolePort* port = handle->port;

	if (!port->present) {
		*_length = 0;
		return B_DEV_NOT_READY;
	}

	MutexLocker locker(port->writeLock);
	int32 index = PORT_INDEX(port->id);
	const uint8* source = (const uint8*)buffer;
	size_t total = *_length;
	size_t done = 0;

	while (done < total) {
		size_t chunk = min_c(total - done, (size_t)BUFFER_SIZE);
		status_t status = user_memcpy(buffer_at(device, index), source + done,
			chunk);
		if (status == B_OK)
			status = send_and_wait(device, port->txQueue, index, chunk);
		if (status != B_OK) {
			*_length = done;
			return done > 0 ? B_OK : status;
		}
		done += chunk;
	}

	*_length = done;
	return B_OK;
}


static status_t
virtio_console_control(void* cookie, uint32 op, void* buffer, size_t length)
{
	return B_DEV_INVALID_IOCTL;
}


//	#pragma mark - driver module API


static float
virtio_console_supports_device(device_node* parent)
{
	const char* bus;
	uint16 deviceType;

	if (sDeviceManager->get_attr_string(parent, B_DEVICE_BUS, &bus, false))
		return -1;
	if (strcmp(bus, "virtio") != 0)
		return 0.0;
	if (sDeviceManager->get_attr_uint16(parent, VIRTIO_DEVICE_TYPE_ITEM,
			&deviceType, true) != B_OK
		|| deviceType != VIRTIO_DEVICE_ID_CONSOLE)
		return 0.0;

	return 0.6;
}


static status_t
virtio_console_register_device(device_node* node)
{
	device_attr attrs[] = {
		{ B_DEVICE_PRETTY_NAME, B_STRING_TYPE, { .string = "VirtIO console" }},
		// the ports and their host state live as long as the driver
		{ B_DEVICE_FLAGS, B_UINT32_TYPE, { .ui32 = B_KEEP_DRIVER_LOADED }},
		{ NULL }
	};

	return sDeviceManager->register_node(node,
		VIRTIO_CONSOLE_DRIVER_MODULE_NAME, attrs, NULL, NULL);
}


static status_t
virtio_console_init_driver(device_node* node, void** _cookie)
{
	ConsoleDevice* device = new(std::nothrow) ConsoleDevice;
	if (device == NULL)
		return B_NO_MEMORY;

	memset((void*)device, 0, sizeof(*device));
	device->node = node;
	device->bufferArea = -1;
	device->workSem = -1;
	device->workThread = -1;
	B_INITIALIZE_SPINLOCK(&device->lock);
	mutex_init(&device->controlTxLock, "virtio_console control");
	device->namesCondition.Init(device, "virtio_console names");
	for (int32 i = 0; i < MAX_PORTS; i++) {
		ConsolePort& port = device->ports[i];
		port.id = i;
		mutex_init(&port.writeLock, "virtio_console write");
		mutex_init(&port.readLock, "virtio_console read");
		port.readCondition.Init(&port, "virtio_console read");
	}

	*_cookie = device;
	return B_OK;
}


static void
virtio_console_uninit_driver(void* _cookie)
{
	ConsoleDevice* device = (ConsoleDevice*)_cookie;

	if (device->workThread >= 0) {
		device->workRunning = false;
		release_sem(device->workSem);
		status_t result;
		wait_for_thread(device->workThread, &result);
	}
	if (device->interruptsSetUp)
		device->virtio->free_interrupts(device->virtioDevice);
	if (device->queuesAllocated)
		device->virtio->free_queues(device->virtioDevice);
	if (device->workSem >= 0)
		delete_sem(device->workSem);
	if (device->bufferArea >= 0)
		delete_area(device->bufferArea);

	mutex_destroy(&device->controlTxLock);
	for (int32 i = 0; i < MAX_PORTS; i++) {
		mutex_destroy(&device->ports[i].writeLock);
		mutex_destroy(&device->ports[i].readLock);
	}
	delete device;
}


static bool
all_names_known(ConsoleDevice* device)
{
	bool any = false;
	for (uint32 i = 0; i < device->portCount; i++) {
		const ConsolePort& port = device->ports[i];
		if (port.present) {
			any = true;
			if (port.name[0] == '\0' && i != 0)
				return false;
		}
	}
	return any;
}


static status_t
virtio_console_register_child_devices(void* _cookie)
{
	ConsoleDevice* device = (ConsoleDevice*)_cookie;

	status_t status = init_hardware(device);
	if (status != B_OK) {
		ERROR("init failed: %s\n", strerror(status));
		return status;
	}

	// The host answers DEVICE_READY with DEVICE_ADD and PORT_NAME for each
	// port; give it a moment so the named devices can be published.
	bigtime_t deadline = system_time() + NAME_WAIT_TIMEOUT;
	while (!all_names_known(device) && system_time() < deadline) {
		ConditionVariableEntry entry;
		device->namesCondition.Add(&entry);
		if (all_names_known(device))
			break;
		entry.Wait(B_RELATIVE_TIMEOUT, 100000);
	}

	for (uint32 i = 0; i < device->portCount; i++) {
		ConsolePort& port = device->ports[i];
		char name[128];
		snprintf(name, sizeof(name), VIRTIO_CONSOLE_DEVICE_DIR "/vport%"
			B_PRId32, port.id);
		sDeviceManager->publish_device(device->node, name,
			VIRTIO_CONSOLE_DEVICE_MODULE_NAME);
		if (port.name[0] != '\0') {
			snprintf(name, sizeof(name), VIRTIO_CONSOLE_DEVICE_DIR "/%s",
				port.name);
			if (sDeviceManager->publish_device(device->node, name,
					VIRTIO_CONSOLE_DEVICE_MODULE_NAME) != B_OK) {
				ERROR("could not publish %s\n", name);
			}
		}
	}

	return B_OK;
}


//	#pragma mark -


module_dependency module_dependencies[] = {
	{ B_DEVICE_MANAGER_MODULE_NAME, (module_info**)&sDeviceManager },
	{ NULL }
};


struct device_module_info sVirtioConsoleDevice = {
	.info = {
		.name = VIRTIO_CONSOLE_DEVICE_MODULE_NAME,
	},

	.init_device = virtio_console_init_device,
	.uninit_device = virtio_console_uninit_device,

	.open = virtio_console_open,
	.close = virtio_console_close,
	.free = virtio_console_free,
	.read = virtio_console_read,
	.write = virtio_console_write,
	.control = virtio_console_control,
};

struct driver_module_info sVirtioConsoleDriver = {
	.info = {
		.name = VIRTIO_CONSOLE_DRIVER_MODULE_NAME,
	},

	.supports_device = virtio_console_supports_device,
	.register_device = virtio_console_register_device,
	.init_driver = virtio_console_init_driver,
	.uninit_driver = virtio_console_uninit_driver,
	.register_child_devices = virtio_console_register_child_devices,
};

module_info* modules[] = {
	(module_info*)&sVirtioConsoleDriver,
	(module_info*)&sVirtioConsoleDevice,
	NULL
};
