#include "AXShim.h"
#include <dlfcn.h>
#include <pthread.h>

typedef AXError (*GetWindowFn)(AXUIElementRef, CGWindowID *);

static GetWindowFn g_getWindow = NULL;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void resolve(void) {
    // リンク時依存にすると、将来 OS からシンボルが消えた場合にアプリが起動すらできなくなる。
    // 実行時解決なら「機能縮退して起動」できるので dlsym を使う。
    g_getWindow = (GetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
}

bool AXShimIsAvailable(void) {
    pthread_once(&g_once, resolve);
    return g_getWindow != NULL;
}

AXError AXShimGetWindowID(AXUIElementRef element, CGWindowID *outWindowID) {
    pthread_once(&g_once, resolve);
    if (g_getWindow == NULL) {
        return kAXErrorNotImplemented;
    }
    if (element == NULL || outWindowID == NULL) {
        return kAXErrorIllegalArgument;
    }
    return g_getWindow(element, outWindowID);
}
