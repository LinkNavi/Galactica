
#ifndef DREAMLAND_MODULE_H
#define DREAMLAND_MODULE_H

#define DREAMLAND_MODULE_API_VERSION 1

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int api_version;
    const char* name;
    const char* version;
    const char* description;
    const char* author;
} DreamlandModuleInfo;

typedef struct {
    const char* name;
    const char* description;
    const char* usage;
    int (*handler)(int argc, char** argv);
} DreamlandCommand;

typedef DreamlandModuleInfo* (*dreamland_module_info_fn)();
typedef int (*dreamland_module_init_fn)();
typedef void (*dreamland_module_cleanup_fn)();
typedef DreamlandCommand* (*dreamland_module_commands_fn)(int* count);

#ifdef __cplusplus
}
#endif

#define DREAMLAND_MODULE_EXPORT extern "C"

#endif
