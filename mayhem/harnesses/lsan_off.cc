// Fleet policy: leak detection is off in every ASan-built fuzz binary (ASan stays on).
extern "C" int __lsan_is_turned_off() { return 1; }
