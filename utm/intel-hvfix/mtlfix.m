// libmtlfix: lets MoltenVK draw on Metal drivers that predate Metal 3.1.
//
// MoltenVK 1.4 binds every vertex buffer with the macOS 14 calls that carry an
// attribute stride. The legacy AMD driver on a 2013 Mac Pro (class
// BronzeMtlRenderCmdEncoder) doesn't implement them and inherits Metal's
// stubs in _MTLCommandEncoder, which raise "unrecognized selector": the first
// draw kills QEMURenderServer. (respondsToSelector: says YES because of those
// stubs, so an NSObject category is never reached.) This replaces the three
// stubs with ones that forward to the pre-14 calls; drivers that implement the
// real methods override them in their own class and are unaffected. A stride
// other than MTLAttributeStrideStatic can't be honored (the driver has no
// dynamic stride) and is reported once.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>

static void note(NSUInteger stride) {
	static int said;
	if (stride != NSUIntegerMax && !said) {
		said = 1;
		fprintf(stderr, "mtlfix: dynamic vertex stride %lu ignored (driver has none)\n",
			(unsigned long)stride);
	}
}

static void fix_setVertexBuffer(id self, SEL _cmd, id<MTLBuffer> buffer, NSUInteger offset,
	NSUInteger stride, NSUInteger index) {
	note(stride);
	[(id<MTLRenderCommandEncoder>)self setVertexBuffer:buffer offset:offset atIndex:index];
}

static void fix_setVertexBufferOffset(id self, SEL _cmd, NSUInteger offset, NSUInteger stride,
	NSUInteger index) {
	note(stride);
	[(id<MTLRenderCommandEncoder>)self setVertexBufferOffset:offset atIndex:index];
}

static void fix_setVertexBuffers(id self, SEL _cmd, const id<MTLBuffer> _Nullable buffers[],
	const NSUInteger offsets[], const NSUInteger strides[], NSRange range) {
	for (NSUInteger i = 0; strides && i < range.length; i++)
		note(strides[i]);
	[(id<MTLRenderCommandEncoder>)self setVertexBuffers:buffers offsets:offsets withRange:range];
}

__attribute__((constructor)) static void mtlfix_init(void) {
	Class base = objc_getClass("_MTLCommandEncoder");
	if (base == Nil) {
		fprintf(stderr, "mtlfix: no _MTLCommandEncoder class, nothing installed\n");
		return;
	}
	struct { SEL sel; IMP imp; } fixes[] = {
		{ @selector(setVertexBuffer:offset:attributeStride:atIndex:), (IMP)fix_setVertexBuffer },
		{ @selector(setVertexBufferOffset:attributeStride:atIndex:), (IMP)fix_setVertexBufferOffset },
		{ @selector(setVertexBuffers:offsets:attributeStrides:withRange:), (IMP)fix_setVertexBuffers },
	};
	int done = 0;
	for (unsigned i = 0; i < sizeof(fixes) / sizeof(fixes[0]); i++) {
		// Only the stub declared on the base class itself: never a driver's own.
		unsigned count = 0;
		Method* methods = class_copyMethodList(base, &count);
		for (unsigned m = 0; m < count; m++) {
			if (method_getName(methods[m]) == fixes[i].sel) {
				method_setImplementation(methods[m], fixes[i].imp);
				done++;
			}
		}
		free(methods);
	}
	fprintf(stderr, "mtlfix: replaced %d vertex-buffer stride stubs\n", done);
}
