/*
 * Copyright 2026, John Zheng. All rights reserved.
 * Distributed under the terms of the MIT License.
 */

/*!	SPICE guest agent for Haiku (UTM / QEMU).

	- Clipboard sharing: talks the vdagent protocol over the virtio-serial
	  port "com.redhat.spice.0" (published by the virtio_console driver).
	  Text goes both ways as UTF-8, images as PNG.
	- Resolution follows the window: QEMU turns the client's monitor config
	  into a virtio-gpu display event, which the virtio_gpu driver exposes
	  via VIRTIO_GPU_3D_WAIT_DISPLAY; we then switch the screen mode.
	  Monitor configs that do reach the agent are applied the same way.
*/


#include <Application.h>
#include <Autolock.h>
#include <Bitmap.h>
#include <BitmapStream.h>
#include <Clipboard.h>
#include <DataIO.h>
#include <Directory.h>
#include <Drivers.h>
#include <Entry.h>
#include <Locker.h>
#include <Path.h>
#include <Screen.h>
#include <String.h>
#include <TranslationUtils.h>
#include <TranslatorFormats.h>
#include <TranslatorRoster.h>

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#include <vector>

#include "spice_protocol.h"


#define AGENT_SIGNATURE		"application/x-vnd.bluevisor-vdagent"
#define PORT_PATH			"/dev/ports/virtio/com.redhat.spice.0"
#define ATTACH_PATH			"/dev/misc/virtio_console_attach"
#define GPU_RENDER_DIR		"/dev/misc/virtio_gpu"

// must match headers/private/graphics/virtio/virtio_gpu_3d.h
#define VIRTIO_GPU_3D_WAIT_DISPLAY	(B_DEVICE_OP_CODES_END + 0x100 + 11)
struct virtio_gpu_3d_wait_display {
	bigtime_t	timeout;
	uint32		width;
	uint32		height;
	uint32		changed;
	uint32		pad;
};

#define MAX_WIDTH			3840
#define MAX_HEIGHT			2160
#define MIN_WIDTH			640
#define MIN_HEIGHT			480
#define RESIZE_SETTLE		250000

static bool sVerbose = false;


static void
log(const char* format, ...)
{
	va_list args;
	va_start(args, format);
	char buffer[512];
	vsnprintf(buffer, sizeof(buffer), format, args);
	va_end(args);
	syslog(LOG_INFO, "vdagent: %s", buffer);
	if (sVerbose)
		fprintf(stderr, "vdagent: %s\n", buffer);
}


//	#pragma mark - display


static void
set_screen_size(uint32 width, uint32 height)
{
	if (width < MIN_WIDTH || height < MIN_HEIGHT)
		return;
	width = std::min(width, (uint32)MAX_WIDTH) & ~1u;
	height = std::min(height, (uint32)MAX_HEIGHT);

	BScreen screen;
	display_mode mode;
	if (screen.GetMode(&mode) != B_OK)
		return;
	if (mode.virtual_width == width && mode.virtual_height == height)
		return;

	mode.virtual_width = width;
	mode.virtual_height = height;
	mode.h_display_start = 0;
	mode.v_display_start = 0;
	display_timing& timing = mode.timing;
	timing.h_display = width;
	timing.h_sync_start = width + 48;
	timing.h_sync_end = width + 80;
	timing.h_total = width + 160;
	timing.v_display = height;
	timing.v_sync_start = height + 3;
	timing.v_sync_end = height + 8;
	timing.v_total = height + 30;
	timing.pixel_clock = (uint32)((uint64)timing.h_total * timing.v_total * 60
		/ 1000);
	mode.space = B_RGB32;

	status_t status = screen.SetMode(&mode, false);
	log("resize to %ux%u: %s", width, height, strerror(status));
}


static status_t
display_thread(void*)
{
	// The render node may not exist yet early in the boot.
	int fd = -1;
	while (fd < 0) {
		BDirectory dir(GPU_RENDER_DIR);
		BEntry entry;
		if (dir.InitCheck() == B_OK && dir.GetNextEntry(&entry) == B_OK) {
			BPath path(&entry);
			fd = open(path.Path(), O_RDWR);
		}
		if (fd < 0)
			snooze(2000000);
	}

	virtio_gpu_3d_wait_display args = {};
	args.timeout = -1;
	if (ioctl(fd, VIRTIO_GPU_3D_WAIT_DISPLAY, &args, sizeof(args)) != 0) {
		log("virtio_gpu has no display-change support (%s); "
			"resize only via monitor config", strerror(errno));
		close(fd);
		return 0;
	}
	log("host display %ux%u", args.width, args.height);

	while (true) {
		args.timeout = B_INFINITE_TIMEOUT;
		if (ioctl(fd, VIRTIO_GPU_3D_WAIT_DISPLAY, &args, sizeof(args)) != 0) {
			if (errno == B_INTERRUPTED)
				continue;
			log("display wait failed: %s", strerror(errno));
			snooze(1000000);
			continue;
		}
		// let a window drag settle
		do {
			args.timeout = RESIZE_SETTLE;
			if (ioctl(fd, VIRTIO_GPU_3D_WAIT_DISPLAY, &args, sizeof(args)) != 0)
				break;
		} while (args.changed);

		set_screen_size(args.width, args.height);
	}
	return 0;
}


//	#pragma mark - agent


class Agent : public BApplication {
public:
								Agent();

	virtual	void				ReadyToRun();
	virtual	void				MessageReceived(BMessage* message);

private:
	static	status_t			_ReaderEntry(void* self);
			void				_Reader();
			void				_HandleMessage(uint32 type, const uint8* data,
									size_t size);
			void				_SendMessage(uint32 type, const void* data,
									size_t size, const void* extra = NULL,
									size_t extraSize = 0);
			void				_AnnounceCapabilities(bool request);

			void				_OnClientGrab(const uint32* types,
									size_t count);
			void				_OnClientData(uint32 type, const uint8* data,
									size_t size);
			void				_OnClientRequest(uint32 type);
			void				_OnLocalClipboardChanged();

			bool				_ClientHas(uint32 cap) const;

			BLocker				fWriteLock;
			int					fPort;
			std::vector<uint32>	fClientCaps;
			uint32				fMaxClipboard;
			uint32				fOwnClipboardCount;
				// system count of the last clipboard we wrote ourselves
			bool				fClientOwnsClipboard;
};


Agent::Agent()
	:
	BApplication(AGENT_SIGNATURE),
	fWriteLock("vdagent write"),
	fPort(-1),
	fMaxClipboard(0),
	fOwnClipboardCount(0),
	fClientOwnsClipboard(false)
{
}


void
Agent::ReadyToRun()
{
	be_clipboard->StartWatching(BMessenger(this));

	resume_thread(spawn_thread(display_thread, "vdagent display",
		B_NORMAL_PRIORITY, NULL));
	resume_thread(spawn_thread(_ReaderEntry, "vdagent reader",
		B_NORMAL_PRIORITY, this));
}


void
Agent::MessageReceived(BMessage* message)
{
	switch (message->what) {
		case B_CLIPBOARD_CHANGED:
			_OnLocalClipboardChanged();
			break;
		default:
			BApplication::MessageReceived(message);
	}
}


/*static*/ status_t
Agent::_ReaderEntry(void* self)
{
	((Agent*)self)->_Reader();
	return 0;
}


static bool
read_fully(int fd, void* buffer, size_t size)
{
	uint8* bytes = (uint8*)buffer;
	while (size > 0) {
		ssize_t bytesRead = read(fd, bytes, size);
		if (bytesRead < 0 && errno == B_INTERRUPTED)
			continue;
		if (bytesRead <= 0)
			return false;
		bytes += bytesRead;
		size -= bytesRead;
	}
	return true;
}


void
Agent::_Reader()
{
	bool warned = false;
	while (true) {
		// virtio_pci is not attached to the console PCI function by default
		// (see virtio_console_attach); opening this node attaches it.
		int attach = open(ATTACH_PATH, O_RDONLY);
		if (attach >= 0)
			close(attach);

		int fd = open(PORT_PATH, O_RDWR);
		if (fd < 0) {
			if (!warned) {
				log("waiting for %s (%s); enable clipboard sharing in UTM",
					PORT_PATH, strerror(errno));
				warned = true;
			}
			snooze(3000000);
			continue;
		}
		warned = false;
		log("connected to %s", PORT_PATH);

		fWriteLock.Lock();
		fPort = fd;
		fClientCaps.clear();
		fWriteLock.Unlock();
		_AnnounceCapabilities(true);

		// Messages may be split across chunks; reassemble them here.
		std::vector<uint8> message;
		size_t wanted = 0;
		while (true) {
			VDIChunkHeader chunk;
			if (!read_fully(fd, &chunk, sizeof(chunk)))
				break;
			std::vector<uint8> data(chunk.size);
			if (chunk.size > 0 && !read_fully(fd, data.data(), chunk.size))
				break;

			message.insert(message.end(), data.begin(), data.end());
			if (wanted == 0 && message.size() >= sizeof(VDAgentMessage)) {
				const VDAgentMessage* header
					= (const VDAgentMessage*)message.data();
				wanted = sizeof(VDAgentMessage) + header->size;
			}
			while (wanted != 0 && message.size() >= wanted) {
				const VDAgentMessage* header
					= (const VDAgentMessage*)message.data();
				if (header->protocol == VD_AGENT_PROTOCOL) {
					_HandleMessage(header->type, message.data()
						+ sizeof(VDAgentMessage), header->size);
				}
				message.erase(message.begin(), message.begin() + wanted);
				wanted = 0;
				if (message.size() >= sizeof(VDAgentMessage)) {
					header = (const VDAgentMessage*)message.data();
					wanted = sizeof(VDAgentMessage) + header->size;
				}
			}
		}

		log("port closed, reconnecting");
		fWriteLock.Lock();
		fPort = -1;
		fWriteLock.Unlock();
		close(fd);
		snooze(1000000);
	}
}


void
Agent::_SendMessage(uint32 type, const void* data, size_t size,
	const void* extra, size_t extraSize)
{
	BAutolock locker(fWriteLock);
	if (fPort < 0)
		return;

	std::vector<uint8> buffer(sizeof(VDAgentMessage) + size + extraSize);
	VDAgentMessage* header = (VDAgentMessage*)buffer.data();
	header->protocol = VD_AGENT_PROTOCOL;
	header->type = type;
	header->opaque = 0;
	header->size = size + extraSize;
	if (size > 0)
		memcpy(buffer.data() + sizeof(VDAgentMessage), data, size);
	if (extraSize > 0)
		memcpy(buffer.data() + sizeof(VDAgentMessage) + size, extra, extraSize);

	size_t offset = 0;
	while (offset < buffer.size()) {
		size_t chunkSize = std::min(buffer.size() - offset,
			(size_t)VD_AGENT_MAX_DATA_SIZE);
		VDIChunkHeader chunk;
		chunk.port = VDP_CLIENT_PORT;
		chunk.size = chunkSize;
		if (write(fPort, &chunk, sizeof(chunk)) != sizeof(chunk)
			|| write(fPort, buffer.data() + offset, chunkSize)
				!= (ssize_t)chunkSize) {
			log("write failed: %s", strerror(errno));
			return;
		}
		offset += chunkSize;
	}
}


void
Agent::_AnnounceCapabilities(bool request)
{
	uint32 caps[2] = {};
	VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_MONITORS_CONFIG);
	VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_REPLY);
	VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND);
	VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_GUEST_LINEEND_LF);
	VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_MAX_CLIPBOARD);
	VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_SPARSE_MONITORS_CONFIG);

	uint32 header = request ? 1 : 0;
	_SendMessage(VD_AGENT_ANNOUNCE_CAPABILITIES, &header, sizeof(header),
		caps, sizeof(caps));
}


bool
Agent::_ClientHas(uint32 cap) const
{
	uint32 index = cap / 32;
	return index < fClientCaps.size()
		&& (fClientCaps[index] & (1u << (cap % 32))) != 0;
}


void
Agent::_HandleMessage(uint32 type, const uint8* data, size_t size)
{
	if (sVerbose)
		log("message type %u size %zu", type, size);

	switch (type) {
		case VD_AGENT_ANNOUNCE_CAPABILITIES:
		{
			if (size < sizeof(uint32))
				return;
			uint32 request = *(const uint32*)data;
			const uint32* caps = (const uint32*)(data + sizeof(uint32));
			fClientCaps.assign(caps, caps + (size - sizeof(uint32)) / 4);
			if (request)
				_AnnounceCapabilities(false);
			break;
		}

		case VD_AGENT_MONITORS_CONFIG:
		{
			const VDAgentMonitorsConfig* config
				= (const VDAgentMonitorsConfig*)data;
			if (size >= sizeof(VDAgentMonitorsConfig) + sizeof(VDAgentMonConfig)
				&& config->num_of_monitors > 0) {
				set_screen_size(config->monitors[0].width,
					config->monitors[0].height);
			}
			VDAgentReply reply = { VD_AGENT_MONITORS_CONFIG, VD_AGENT_SUCCESS };
			_SendMessage(VD_AGENT_REPLY, &reply, sizeof(reply));
			break;
		}

		case VD_AGENT_CLIPBOARD_GRAB:
			_OnClientGrab((const uint32*)data, size / sizeof(uint32));
			break;

		case VD_AGENT_CLIPBOARD_REQUEST:
			if (size >= sizeof(uint32))
				_OnClientRequest(*(const uint32*)data);
			break;

		case VD_AGENT_CLIPBOARD:
			if (size >= sizeof(uint32)) {
				_OnClientData(*(const uint32*)data, data + sizeof(uint32),
					size - sizeof(uint32));
			}
			break;

		case VD_AGENT_CLIPBOARD_RELEASE:
			fClientOwnsClipboard = false;
			break;

		case VD_AGENT_MAX_CLIPBOARD:
			if (size >= sizeof(uint32))
				fMaxClipboard = *(const uint32*)data;
			break;

		case VD_AGENT_CLIENT_DISCONNECTED:
			fClientOwnsClipboard = false;
			break;

		default:
			break;
	}
}


//	#pragma mark - clipboard


void
Agent::_OnClientGrab(const uint32* types, size_t count)
{
	// Haiku has no deferred clipboard, so fetch the data right away.
	uint32 wanted = VD_AGENT_CLIPBOARD_NONE;
	for (size_t i = 0; i < count; i++) {
		if (types[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
			wanted = types[i];
			break;
		}
		if (types[i] == VD_AGENT_CLIPBOARD_IMAGE_PNG)
			wanted = types[i];
	}
	fClientOwnsClipboard = true;
	if (wanted != VD_AGENT_CLIPBOARD_NONE)
		_SendMessage(VD_AGENT_CLIPBOARD_REQUEST, &wanted, sizeof(wanted));
}


void
Agent::_OnClientData(uint32 type, const uint8* data, size_t size)
{
	if (!be_clipboard->Lock())
		return;

	be_clipboard->Clear();
	BMessage* clip = be_clipboard->Data();
	bool filled = false;

	if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
		// drop a trailing NUL some clients include
		while (size > 0 && data[size - 1] == '\0')
			size--;
		clip->AddData("text/plain", B_MIME_TYPE, data, size);
		filled = true;
	} else if (type == VD_AGENT_CLIPBOARD_IMAGE_PNG) {
		BMemoryIO input(data, size);
		BBitmap* bitmap = BTranslationUtils::GetBitmap(&input);
		if (bitmap != NULL) {
			BMessage archive;
			if (bitmap->Archive(&archive) == B_OK) {
				clip->AddMessage("image/bitmap", &archive);
				filled = true;
			}
			delete bitmap;
		}
		clip->AddData("image/png", B_MIME_TYPE, data, size);
		filled = true;
	}

	if (filled) {
		be_clipboard->Commit();
		fOwnClipboardCount = be_clipboard->SystemCount();
	}
	be_clipboard->Unlock();
	log("host clipboard -> guest (type %u, %zu bytes)", type, size);
}


static bool
local_png(BMessage* clip, BMallocIO& output)
{
	const void* png;
	ssize_t pngSize;
	if (clip->FindData("image/png", B_MIME_TYPE, &png, &pngSize) == B_OK) {
		output.Write(png, pngSize);
		return true;
	}

	BMessage archive;
	if (clip->FindMessage("image/bitmap", &archive) != B_OK)
		return false;
	BBitmap* bitmap = new(std::nothrow) BBitmap(&archive);
	if (bitmap == NULL || bitmap->InitCheck() != B_OK) {
		delete bitmap;
		return false;
	}
	BBitmapStream stream(bitmap);
	status_t status = BTranslatorRoster::Default()->Translate(&stream, NULL,
		NULL, &output, B_PNG_FORMAT);
	BBitmap* detached;
	stream.DetachBitmap(&detached);
	delete detached;
	return status == B_OK;
}


void
Agent::_OnLocalClipboardChanged()
{
	if (!be_clipboard->Lock())
		return;
	if (be_clipboard->SystemCount() == fOwnClipboardCount) {
		be_clipboard->Unlock();
		return;
	}

	BMessage* clip = be_clipboard->Data();
	std::vector<uint32> types;
	if (clip->HasData("text/plain", B_MIME_TYPE))
		types.push_back(VD_AGENT_CLIPBOARD_UTF8_TEXT);
	if (clip->HasData("image/png", B_MIME_TYPE)
		|| clip->HasMessage("image/bitmap"))
		types.push_back(VD_AGENT_CLIPBOARD_IMAGE_PNG);
	be_clipboard->Unlock();

	if (types.empty()) {
		if (!fClientOwnsClipboard)
			_SendMessage(VD_AGENT_CLIPBOARD_RELEASE, NULL, 0);
		return;
	}
	fClientOwnsClipboard = false;
	_SendMessage(VD_AGENT_CLIPBOARD_GRAB, types.data(),
		types.size() * sizeof(uint32));
}


void
Agent::_OnClientRequest(uint32 type)
{
	BMallocIO output;
	if (be_clipboard->Lock()) {
		BMessage* clip = be_clipboard->Data();
		if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
			const void* text;
			ssize_t textSize;
			if (clip->FindData("text/plain", B_MIME_TYPE, &text, &textSize)
					== B_OK) {
				output.Write(text, textSize);
			}
		} else if (type == VD_AGENT_CLIPBOARD_IMAGE_PNG)
			local_png(clip, output);
		be_clipboard->Unlock();
	}

	if (fMaxClipboard != 0 && output.BufferLength() > fMaxClipboard) {
		log("clipboard too large for the client (%zu > %u)",
			output.BufferLength(), fMaxClipboard);
		type = VD_AGENT_CLIPBOARD_NONE;
		output.SetSize(0);
	}

	_SendMessage(VD_AGENT_CLIPBOARD, &type, sizeof(type), output.Buffer(),
		output.BufferLength());
	log("guest clipboard -> host (type %u, %zu bytes)", type,
		output.BufferLength());
}


int
main(int argc, char** argv)
{
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-v") == 0)
			sVerbose = true;
	}
	openlog("vdagent", LOG_PID, LOG_USER);

	Agent agent;
	agent.Run();
	return 0;
}
