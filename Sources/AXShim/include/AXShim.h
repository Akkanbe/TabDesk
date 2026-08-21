#ifndef AXSHIM_H
#define AXSHIM_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

/// 私有関数 _AXUIElementGetWindow(AXUIElementRef → CGWindowID)を呼ぶ。
/// 戻り値は _AXUIElementGetWindow の AXError をそのまま返す(失敗理由を呼び出し側で記録するため)。
/// シンボルが無い OS では kAXErrorNotImplemented(クラッシュしない)。
AXError AXShimGetWindowID(AXUIElementRef element, CGWindowID *outWindowID);

/// 私有シンボルを解決できたか(診断用)。
bool AXShimIsAvailable(void);

#endif
