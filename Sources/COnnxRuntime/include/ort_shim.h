#ifndef HS_ORT_SHIM_H
#define HS_ORT_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 不透明的会话句柄。Swift 侧按 OpaquePointer 使用。
typedef struct HSSession HSSession;

/// 创建推理会话。成功返回句柄，失败返回 NULL 并把原因写入 errbuf。
HSSession *hs_session_create(const char *model_path, char *errbuf, size_t errlen);

void hs_session_destroy(HSSession *session);

/// 单输入、单输出的推理调用。
///
/// input      : NCHW 排布的 float 数组，长度 = shape 各维乘积
/// shape/dims : 输入张量形状
/// out_data   : 输出数据，调用方用 hs_free 释放
/// out_shape  : 输出形状，调用方用 hs_free 释放
///
/// 返回 1 表示成功，0 表示失败（原因写入 errbuf）。
int hs_session_run(HSSession *session,
                   const float *input, const int64_t *shape, int dims,
                   float **out_data, int64_t **out_shape, int *out_dims,
                   char *errbuf, size_t errlen);

/// 取输入/输出张量名，便于排查模型不匹配。
int hs_session_io_names(HSSession *session,
                        char *input_name, size_t inlen,
                        char *output_name, size_t outlen);

void hs_free(void *pointer);

/// onnxruntime 版本字符串，用于日志。
const char *hs_ort_version(void);

#ifdef __cplusplus
}
#endif

#endif /* HS_ORT_SHIM_H */
