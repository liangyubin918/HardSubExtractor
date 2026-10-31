#include "ort_shim.h"

// 关键技巧：把头文件里 OrtGetApiBase 的声明改名，这样我们就不会在链接期
// 依赖 onnxruntime 的符号，改为运行时 dlopen + dlsym 拿函数地址。
// 好处是缺库时应用照常启动，只是 PaddleOCR 显示为不可用，而不是直接崩溃。
#define OrtGetApiBase hs_unused_ort_get_api_base_decl
#include "onnxruntime_c_api.h"
#undef OrtGetApiBase

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct HSSession {
    OrtSession *session;
    OrtMemoryInfo *memory_info;
    char input_name[256];
    char output_name[256];
};

static const OrtApi *g_api = NULL;
static OrtEnv *g_env = NULL;
static char g_load_error[512] = {0};

static void hs_exe_dir(char *buffer, size_t length) {
    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        snprintf(buffer, length, ".");
        return;
    }
    char *slash = strrchr(path, '/');
    if (slash) *slash = '\0';
    snprintf(buffer, length, "%s", path);
}

static const OrtApiBase *hs_load_api_base(void) {
    static const OrtApiBase *base = NULL;
    static int attempted = 0;
    if (attempted) return base;
    attempted = 1;

    char exe_dir[4096];
    hs_exe_dir(exe_dir, sizeof(exe_dir));

    char candidates[8][4096];
    int count = 0;

    const char *env = getenv("HS_ONNXRUNTIME_PATH");
    if (env && env[0]) snprintf(candidates[count++], 4096, "%s", env);

    snprintf(candidates[count++], 4096, "%s/libonnxruntime.1.dylib", exe_dir);
    snprintf(candidates[count++], 4096, "%s/../Frameworks/libonnxruntime.1.dylib", exe_dir);
    snprintf(candidates[count++], 4096, "%s/../../Vendor/onnxruntime/lib/libonnxruntime.1.dylib", exe_dir);
    snprintf(candidates[count++], 4096, "%s/../../../Vendor/onnxruntime/lib/libonnxruntime.1.dylib", exe_dir);
    snprintf(candidates[count++], 4096, "@rpath/libonnxruntime.1.dylib");
    snprintf(candidates[count++], 4096, "/opt/homebrew/lib/libonnxruntime.1.dylib");

    void *handle = NULL;
    for (int i = 0; i < count && !handle; i++) {
        handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
    }

    if (!handle) {
        const char *reason = dlerror();
        snprintf(g_load_error, sizeof(g_load_error),
                 "无法加载 libonnxruntime：%s", reason ? reason : "未知原因");
        return NULL;
    }

    typedef const OrtApiBase *(*GetApiBaseFn)(void);
    GetApiBaseFn get_base = (GetApiBaseFn)dlsym(handle, "OrtGetApiBase");
    if (!get_base) {
        snprintf(g_load_error, sizeof(g_load_error), "动态库中找不到 OrtGetApiBase 符号");
        return NULL;
    }

    base = get_base();
    if (!base) {
        snprintf(g_load_error, sizeof(g_load_error), "OrtGetApiBase 返回空");
    }
    return base;
}

static const OrtApi *hs_api(char *errbuf, size_t errlen) {
    if (g_api) return g_api;

    const OrtApiBase *base = hs_load_api_base();
    if (!base) {
        snprintf(errbuf, errlen, "%s", g_load_error[0] ? g_load_error : "onnxruntime 不可用");
        return NULL;
    }

    g_api = base->GetApi(ORT_API_VERSION);
    if (!g_api) {
        snprintf(errbuf, errlen, "onnxruntime 版本不兼容：需要 API %d，当前为 %s",
                 ORT_API_VERSION, base->GetVersionString());
        return NULL;
    }
    return g_api;
}

const char *hs_ort_version(void) {
    const OrtApiBase *base = hs_load_api_base();
    return base ? base->GetVersionString() : "unavailable";
}

static int hs_env(const OrtApi *api, char *errbuf, size_t errlen) {
    if (g_env) return 1;
    OrtStatus *status = api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "hardsub", &g_env);
    if (status) {
        snprintf(errbuf, errlen, "创建 onnxruntime 环境失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return 0;
    }
    return 1;
}

static void hs_copy_name(OrtAllocator *allocator, char *destination, size_t length, char *source) {
    if (!source) {
        destination[0] = '\0';
        return;
    }
    snprintf(destination, length, "%s", source);
    allocator->Free(allocator, source);
}

HSSession *hs_session_create(const char *model_path, char *errbuf, size_t errlen) {
    if (errbuf && errlen) errbuf[0] = '\0';

    const OrtApi *api = hs_api(errbuf, errlen);
    if (!api) return NULL;
    if (!hs_env(api, errbuf, errlen)) return NULL;

    OrtSessionOptions *options = NULL;
    OrtStatus *status = api->CreateSessionOptions(&options);
    if (status) {
        snprintf(errbuf, errlen, "创建会话选项失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return NULL;
    }
    (void)api->SetIntraOpNumThreads(options, 2);
    (void)api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL);

    OrtSession *session = NULL;
    status = api->CreateSession(g_env, model_path, options, &session);
    (void)api->ReleaseSessionOptions(options);
    if (status) {
        snprintf(errbuf, errlen, "加载模型失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return NULL;
    }

    OrtMemoryInfo *memory_info = NULL;
    status = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory_info);
    if (status) {
        snprintf(errbuf, errlen, "创建内存信息失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        api->ReleaseSession(session);
        return NULL;
    }

    HSSession *result = (HSSession *)calloc(1, sizeof(HSSession));
    result->session = session;
    result->memory_info = memory_info;

    OrtAllocator *allocator = NULL;
    (void)api->GetAllocatorWithDefaultOptions(&allocator);

    char *name = NULL;
    if (api->SessionGetInputName(session, 0, allocator, &name) == NULL) {
        hs_copy_name(allocator, result->input_name, sizeof(result->input_name), name);
    }
    if (api->SessionGetOutputName(session, 0, allocator, &name) == NULL) {
        hs_copy_name(allocator, result->output_name, sizeof(result->output_name), name);
    }

    return result;
}

void hs_session_destroy(HSSession *session) {
    if (!session) return;
    if (g_api) {
        if (session->session) g_api->ReleaseSession(session->session);
        if (session->memory_info) g_api->ReleaseMemoryInfo(session->memory_info);
    }
    free(session);
}

int hs_session_io_names(HSSession *session,
                        char *input_name, size_t inlen,
                        char *output_name, size_t outlen) {
    if (!session) return 0;
    snprintf(input_name, inlen, "%s", session->input_name);
    snprintf(output_name, outlen, "%s", session->output_name);
    return 1;
}

int hs_session_run(HSSession *session,
                   const float *input, const int64_t *shape, int dims,
                   float **out_data, int64_t **out_shape, int *out_dims,
                   char *errbuf, size_t errlen) {
    if (errbuf && errlen) errbuf[0] = '\0';
    if (!session) {
        snprintf(errbuf, errlen, "会话为空");
        return 0;
    }

    const OrtApi *api = g_api;
    if (!api) {
        snprintf(errbuf, errlen, "onnxruntime 未初始化");
        return 0;
    }

    size_t element_count = 1;
    for (int i = 0; i < dims; i++) {
        if (shape[i] <= 0) {
            snprintf(errbuf, errlen, "输入形状非法");
            return 0;
        }
        element_count *= (size_t)shape[i];
    }

    OrtValue *input_tensor = NULL;
    OrtStatus *status = api->CreateTensorWithDataAsOrtValue(
        session->memory_info,
        (void *)input,
        element_count * sizeof(float),
        shape,
        (size_t)dims,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &input_tensor);

    if (status) {
        snprintf(errbuf, errlen, "创建输入张量失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return 0;
    }

    const char *input_names[1] = { session->input_name };
    const char *output_names[1] = { session->output_name };
    const OrtValue *inputs[1] = { input_tensor };
    OrtValue *outputs[1] = { NULL };

    status = api->Run(session->session, NULL, input_names, inputs, 1, output_names, 1, outputs);
    (void)api->ReleaseValue(input_tensor);

    if (status) {
        snprintf(errbuf, errlen, "推理失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return 0;
    }

    OrtTensorTypeAndShapeInfo *info = NULL;
    status = api->GetTensorTypeAndShape(outputs[0], &info);
    if (status) {
        snprintf(errbuf, errlen, "读取输出形状失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        (void)api->ReleaseValue(outputs[0]);
        return 0;
    }

    size_t rank = 0;
    (void)api->GetDimensionsCount(info, &rank);
    int64_t *dims_buffer = (int64_t *)malloc(sizeof(int64_t) * (rank == 0 ? 1 : rank));
    if (!dims_buffer) {
        snprintf(errbuf, errlen, "内存不足");
        api->ReleaseTensorTypeAndShapeInfo(info);
        api->ReleaseValue(outputs[0]);
        return 0;
    }
    (void)api->GetDimensions(info, dims_buffer, rank);

    size_t output_count = 0;
    (void)api->GetTensorShapeElementCount(info, &output_count);
    (void)api->ReleaseTensorTypeAndShapeInfo(info);

    void *raw = NULL;
    status = api->GetTensorMutableData(outputs[0], &raw);
    if (status) {
        snprintf(errbuf, errlen, "读取输出数据失败：%s", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        free(dims_buffer);
        (void)api->ReleaseValue(outputs[0]);
        return 0;
    }

    float *copy = (float *)malloc(sizeof(float) * (output_count == 0 ? 1 : output_count));
    if (!copy) {
        snprintf(errbuf, errlen, "内存不足");
        free(dims_buffer);
        api->ReleaseValue(outputs[0]);
        return 0;
    }
    if (output_count > 0) memcpy(copy, raw, sizeof(float) * output_count);

    *out_data = copy;
    *out_shape = dims_buffer;
    *out_dims = (int)rank;

    (void)api->ReleaseValue(outputs[0]);
    return 1;
}

void hs_free(void *pointer) {
    free(pointer);
}
