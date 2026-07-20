/*
 * lw_c_api.h — flat C control-plane ABI. PLACEHOLDER.
 *
 * The full control surface is authored in the libwebrtc fork and vendored
 * here for ffigen. It includes lw_video_sink.h. Until the control API lands
 * upstream this header only pulls in the data-plane ABI so ffigen has a valid
 * entry point.
 */
#ifndef LW_C_API_H_
#define LW_C_API_H_

#include "lw_video_sink.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Returns the LW_ABI_VERSION the loaded libwebrtc.so was built against. */
int lw_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* LW_C_API_H_ */
