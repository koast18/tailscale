//
//  KPFishhook.h
//  LCProxyTweak
//
#ifndef KPFishhook_h
#define KPFishhook_h

/// 在进程内所有 image 的符号指针槽中 rebind 目标 C 符号。
/// name 不带前导下划线；replaced 可空，回填原实现地址。
void kp_rebind_symbol(const char *name, void *replacement, void **replaced);

#endif
