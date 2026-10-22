// grab OUT: write the current screen as a portable pixmap (P6, RGB).
#include <Application.h>
#include <Bitmap.h>
#include <Screen.h>
#include <stdio.h>

int main(int argc, char** argv)
{
	if (argc != 2) { fprintf(stderr, "usage: grab out.ppm\n"); return 2; }
	BApplication app("application/x-vnd.bluevisor-grab");
	BScreen screen;
	BBitmap* bitmap = NULL;
	if (screen.GetBitmap(&bitmap, false) != B_OK || bitmap == NULL) { fprintf(stderr, "GetBitmap failed\n"); return 1; }
	BRect r = bitmap->Bounds();
	int w = r.IntegerWidth() + 1, h = r.IntegerHeight() + 1;
	FILE* f = fopen(argv[1], "wb");
	if (f == NULL) { perror(argv[1]); return 1; }
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	const uint8* base = (const uint8*)bitmap->Bits();
	int32 bpr = bitmap->BytesPerRow();
	for (int y = 0; y < h; y++) {
		const uint8* row = base + y * bpr;
		for (int x = 0; x < w; x++) {
			uint8 rgb[3] = { row[x * 4 + 2], row[x * 4 + 1], row[x * 4 + 0] };  // B_RGB32 is BGRA
			fwrite(rgb, 1, 3, f);
		}
	}
	fclose(f);
	printf("%dx%d (colorspace 0x%x)\n", w, h, bitmap->ColorSpace());
	delete bitmap;
	return 0;
}
