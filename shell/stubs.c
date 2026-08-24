/* Stubs for long double math symbols that musl needs but our shell doesn't use. */
#include <stdint.h>
long double __fixtfsi(long double x) { return (long)x; }
long double __floatsitf(int x) { return (long double)x; }
long double __fixunstfsi(unsigned long x) { return (long)x; }
long double __floatunsitf(unsigned x) { return (long double)x; }
long double __fixsfti(long x) { return (long double)x; }
long double __floatditf(long x) { return (long double)x; }
long double __fixdfti(double x) { return (long double)x; }
long double __floatdxtf(double x) { return (long double)x; }
long double __fixtfdi(long double x) { return (long)x; }
long double __floatditf_long(long x) { return (long double)x; }
long double __fixdfti_long(double x) { return (long double)x; }
long double __floatdxtf_long(double x) { return (long double)x; }
long double __floatunditf(unsigned long x) { return (long double)x; }
long double __floatundxtf(unsigned long x) { return (long double)x; }
int __eqtf2(long double a, long double b) { return a == b; }
int __netf2(long double a, long double b) { return a != b; }
int __lttf2(long double a, long double b) { return a < b; }
int __letf2(long double a, long double b) { return a <= b; }
int __gttf2(long double a, long double b) { return a > b; }
int __getf2(long double a, long double b) { return a >= b; }
int __cmptf2(long double a, long double b) { return a < b ? -1 : a > b ? 1 : 0; }
int __unordtf2(long double a, long double b) { return a != a || b != b; }
long double __addtf3(long double a, long double b) { return a + b; }
long double __subtf3(long double a, long double b) { return a - b; }
long double __multf3(long double a, long double b) { return a * b; }
long double __divtf3(long double a, long double b) { return a / b; }
long double __negtf2(long double a) { return -a; }
long double __extendsftf2(float x) { return (long double)x; }
long double __extenddftf2(double x) { return (long double)x; }
double __trunctfdf2(long double x) { return (double)x; }
float __trunctfsf2(long double x) { return (float)x; }
int64_t __fixunstfti(long double x) { return (int64_t)x; }
int64_t __fixstfti(long double x) { return (int64_t)x; }
