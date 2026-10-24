/*
 * Functions Zig 0.16's std links on Haiku that hrev60290's libroot doesn't
 * export. Added to the prebuilt libghostty-vt.a so its consumers link as is.
 * Haiku's <bsd/sys/uio.h> has preadv/pwritev only as header inlines, so this
 * file doesn't include it and calls writev_pos() like those inlines do.
 */
#include <stddef.h>
#include <sys/types.h>


struct iovec;
struct dl_phdr_info;

ssize_t writev_pos(int fd, off_t pos, const struct iovec* vec, int count);


ssize_t
pwritev(int fd, const struct iovec* vecs, int count, off_t pos)
{
	return writev_pos(fd, pos, vecs, count);
}


/* Only std.debug's stack unwinding walks the loaded images: report none. */
int
dl_iterate_phdr(int (*callback)(struct dl_phdr_info*, size_t, void*),
	void* data)
{
	(void)callback;
	(void)data;
	return 0;
}
