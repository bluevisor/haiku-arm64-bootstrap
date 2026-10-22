/*
 * R Chromium 154 was built against Haiku headers where RLIM_INFINITY was
 * 0xffffffff. Since then Haiku made it __HAIKU_ADDR_MAX (all ones), so
 * getrlimit(RLIMIT_AS/RLIMIT_DATA) returns a value the binary reads as -1,
 * and base::AmountOfVirtualMemory() trips a CHECK (brk #1, reported as
 * SIGBUS BUS_ADRALN). Preloaded into R Chromium only, this translates
 * "unlimited" between the two encodings in both directions.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/resource.h>

#define OLD_RLIM_INFINITY ((rlim_t)0xffffffffUL)

int
getrlimit(int resource, struct rlimit* limit)
{
	static int (*real)(int, struct rlimit*);
	if (real == NULL)
		real = (int (*)(int, struct rlimit*))dlsym(RTLD_NEXT, "getrlimit");
	int result = real(resource, limit);
	if (result == 0) {
		if (limit->rlim_cur == RLIM_INFINITY)
			limit->rlim_cur = OLD_RLIM_INFINITY;
		if (limit->rlim_max == RLIM_INFINITY)
			limit->rlim_max = OLD_RLIM_INFINITY;
	}
	return result;
}

int
setrlimit(int resource, const struct rlimit* limit)
{
	static int (*real)(int, const struct rlimit*);
	if (real == NULL)
		real = (int (*)(int, const struct rlimit*))dlsym(RTLD_NEXT, "setrlimit");
	struct rlimit translated = *limit;
	if (translated.rlim_cur == OLD_RLIM_INFINITY)
		translated.rlim_cur = RLIM_INFINITY;
	if (translated.rlim_max == OLD_RLIM_INFINITY)
		translated.rlim_max = RLIM_INFINITY;
	return real(resource, &translated);
}
