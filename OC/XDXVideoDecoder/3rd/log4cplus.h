#include <syslog.h>
#ifndef XDX_IOS
#define XDX_IOS
#endif

#define kXDXDebugMode

#ifdef kXDXDebugMode //使用系统打印函数
    #define log4cplus_fatal(category, logFmt, ...) \
    syslog(LOG_CRIT, "%s:" logFmt, category,##__VA_ARGS__); \

    #define log4cplus_error(category, logFmt, ...) \
    syslog(LOG_ERR, "%s:" logFmt, category,##__VA_ARGS__); \

    #define log4cplus_warn(category, logFmt, ...) \
    syslog(LOG_WARNING, "%s:" logFmt, category,##__VA_ARGS__); \

    #define log4cplus_info(category, logFmt, ...) \
    syslog(LOG_WARNING, "%s:" logFmt, category,##__VA_ARGS__); \

    #define log4cplus_debug(category, logFmt, ...) \
    syslog(LOG_WARNING, "%s:" logFmt, category,##__VA_ARGS__); \

#else //release模式不进行打印
    #define log4cplus_fatal(category, logFmt, ...); \

    #define log4cplus_error(category, logFmt, ...); \

    #define log4cplus_warn(category, logFmt, ...); \

    #define log4cplus_info(category, logFmt, ...); \

    #define log4cplus_debug(category, logFmt, ...); \

#endif

