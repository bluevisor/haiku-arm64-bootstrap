#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *h = dlopen("/Applications/UTM.app/Contents/Frameworks/qemu-img.framework/qemu-img", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int (*qmain)(int, char **) = (int (*)(int, char **))dlsym(h, "main");
    if (!qmain) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 1; }
    return qmain(argc, argv);
}
