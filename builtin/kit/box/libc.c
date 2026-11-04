/* http://www.apache.org/licenses/LICENSE-2.0
** Copyright 2026 Perttu Ahola <celeron55@gmail.com>
**
** [KIT] The Kit box's libc: what Lua 5.1 (lua/) needs in a wasm built
** with -nostdlib, and nothing else. ASCII ctype, the C locale, no files.
** simplified: the number formatting and parsing below are exact for
** integers and for the usual short decimals, within an ulp or two
** elsewhere (no correctly rounded shortest digits); a port of a libc's
** (musl's) is the upgrade if a component ever needs bit-exact text. */
#include "include/libc.h"
#include <stdint.h>
#include <limits.h>

int errno;

/* ---- Memory: power-of-two size classes, each a free list, carved from
** the end of the module's memory. simplified: freed blocks are never given
** back or merged; the classes waste up to half a block. A cap keeps Lua's
** heap inside the box (an allocation past it fails, which Lua raises as a
** "not enough memory" error). */
#define HEAP_CAP (40u << 20)
#define CLASSES 26
extern unsigned char __heap_base;
static uintptr_t g_top;
static size_t g_used;
static void *g_free[CLASSES];

static int size_class(size_t n)
{
	int k = 0;
	size_t s = 16;
	while(s < n + 8){
		s <<= 1;
		if(++k >= CLASSES)
			return -1;
	}
	return k;
}

void *malloc(size_t n)
{
	const int k = size_class(n ? n : 1);
	if(k < 0)
		return NULL;
	if(g_free[k]){
		void *p = g_free[k];
		g_free[k] = *(void**)p;
		return p;
	}
	const size_t s = (size_t)16 << k;
	if(g_used + s > HEAP_CAP)
		return NULL;
	if(!g_top)
		g_top = ((uintptr_t)&__heap_base + 15) & ~(uintptr_t)15;
	const uintptr_t end = g_top + s;
	const uintptr_t have = __builtin_wasm_memory_size(0) * 65536u;
	if(end > have && __builtin_wasm_memory_grow(0,
			(end - have + 65535) / 65536) == (size_t)-1)
		return NULL;
	*(uint32_t*)g_top = (uint32_t)k;
	void *p = (void*)(g_top + 8);
	g_top = end;
	g_used += s;
	return p;
}

void free(void *p)
{
	if(!p)
		return;
	const uint32_t k = *(uint32_t*)((char*)p - 8);
	*(void**)p = g_free[k];
	g_free[k] = p;
}

void *realloc(void *p, size_t n)
{
	if(!p)
		return malloc(n);
	const uint32_t k = *(uint32_t*)((char*)p - 8);
	const size_t have = ((size_t)16 << k) - 8;
	if(n <= have && (k == 0 || n > have / 2))
		return p;
	void *q = malloc(n);
	if(!q)
		return NULL;
	memcpy(q, p, n < have ? n : have);
	free(p);
	return q;
}

/* ---- string.h */
void *memcpy(void *d, const void *s, size_t n)
{
	return __builtin_memcpy(d, s, n);
}
void *memmove(void *d, const void *s, size_t n)
{
	return __builtin_memmove(d, s, n);
}
void *memset(void *d, int c, size_t n)
{
	return __builtin_memset(d, c, n);
}
int memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *x = a, *y = b;
	for(; n; n--, x++, y++)
		if(*x != *y)
			return *x - *y;
	return 0;
}
void *memchr(const void *s, int c, size_t n)
{
	const unsigned char *p = s;
	for(; n; n--, p++)
		if(*p == (unsigned char)c)
			return (void*)p;
	return NULL;
}
size_t strlen(const char *s)
{
	const char *p = s;
	while(*p)
		p++;
	return p - s;
}
int strcmp(const char *a, const char *b)
{
	while(*a && *a == *b)
		a++, b++;
	return (unsigned char)*a - (unsigned char)*b;
}
int strncmp(const char *a, const char *b, size_t n)
{
	for(; n; n--, a++, b++)
		if(*a != *b || !*a)
			return (unsigned char)*a - (unsigned char)*b;
	return 0;
}
int strcoll(const char *a, const char *b)
{
	return strcmp(a, b);
}
char *strcpy(char *d, const char *s)
{
	char *r = d;
	while((*d++ = *s++))
		;
	return r;
}
char *strncpy(char *d, const char *s, size_t n)
{
	char *r = d;
	for(; n && *s; n--)
		*d++ = *s++;
	for(; n; n--)
		*d++ = 0;
	return r;
}
char *strcat(char *d, const char *s)
{
	strcpy(d + strlen(d), s);
	return d;
}
char *strncat(char *d, const char *s, size_t n)
{
	char *p = d + strlen(d);
	for(; n && *s; n--)
		*p++ = *s++;
	*p = 0;
	return d;
}
char *strchr(const char *s, int c)
{
	for(;; s++){
		if(*s == (char)c)
			return (char*)s;
		if(!*s)
			return NULL;
	}
}
char *strrchr(const char *s, int c)
{
	const char *r = NULL;
	for(;; s++){
		if(*s == (char)c)
			r = s;
		if(!*s)
			return (char*)r;
	}
}
char *strstr(const char *h, const char *n)
{
	const size_t k = strlen(n);
	for(; *h; h++)
		if(!strncmp(h, n, k))
			return (char*)h;
	return k ? NULL : (char*)h;
}
size_t strspn(const char *s, const char *a)
{
	size_t n = 0;
	while(s[n] && strchr(a, s[n]))
		n++;
	return n;
}
size_t strcspn(const char *s, const char *a)
{
	size_t n = 0;
	while(s[n] && !strchr(a, s[n]))
		n++;
	return n;
}
char *strpbrk(const char *s, const char *a)
{
	s += strcspn(s, a);
	return *s ? (char*)s : NULL;
}
char *strerror(int e)
{
	(void)e;
	return "error";
}

/* ---- ctype.h, ASCII */
int isdigit(int c){ return c >= '0' && c <= '9'; }
int islower(int c){ return c >= 'a' && c <= 'z'; }
int isupper(int c){ return c >= 'A' && c <= 'Z'; }
int isalpha(int c){ return islower(c) || isupper(c); }
int isalnum(int c){ return isalpha(c) || isdigit(c); }
int isspace(int c){ return c == ' ' || (c >= '\t' && c <= '\r'); }
int iscntrl(int c){ return (c >= 0 && c < 32) || c == 127; }
int isprint(int c){ return c >= 32 && c < 127; }
int isgraph(int c){ return c > 32 && c < 127; }
int ispunct(int c){ return isgraph(c) && !isalnum(c); }
int isxdigit(int c){ return isdigit(c) || ((c | 32) >= 'a' && (c | 32) <= 'f'); }
int tolower(int c){ return isupper(c) ? c + 32 : c; }
int toupper(int c){ return islower(c) ? c - 32 : c; }

/* ---- stdlib.h */
void abort(void){ __builtin_trap(); }
void exit(int status){ (void)status; __builtin_trap(); }
int abs(int x){ return x < 0 ? -x : x; }

static const double P10[] = {1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8,
		1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19,
		1e20, 1e21, 1e22};

/* x * 10^e */
static double scale10(double x, int e)
{
	while(e > 22){
		x *= 1e22;
		e -= 22;
	}
	while(e < -22){
		x /= 1e22;
		e += 22;
	}
	return e >= 0 ? x * P10[e] : x / P10[-e];
}

double strtod(const char *s, char **end)
{
	const char *p = s;
	while(isspace((unsigned char)*p))
		p++;
	int neg = 0;
	if(*p == '+' || *p == '-')
		neg = *p++ == '-';
	uint64_t m = 0;
	int digits = 0, e = 0;
	for(; isdigit((unsigned char)*p); p++, digits++){
		if(m < 1000000000000000000ull)
			m = m * 10 + (*p - '0');
		else
			e++;
	}
	if(*p == '.'){
		p++;
		for(; isdigit((unsigned char)*p); p++, digits++){
			if(m < 1000000000000000000ull){
				m = m * 10 + (*p - '0');
				e--;
			}
		}
	}
	if(!digits){
		if(end)
			*end = (char*)s;
		return 0;
	}
	if(*p == 'e' || *p == 'E'){
		const char *q = p + 1;
		int eneg = 0, x = 0;
		if(*q == '+' || *q == '-')
			eneg = *q++ == '-';
		if(isdigit((unsigned char)*q)){
			for(; isdigit((unsigned char)*q); q++)
				if(x < 10000)
					x = x * 10 + (*q - '0');
			e += eneg ? -x : x;
			p = q;
		}
	}
	if(end)
		*end = (char*)p;
	double r = m == 0 ? 0 : e < -400 ? 0 : e > 400 ? HUGE_VAL :
			scale10((double)m, e);
	if(r == HUGE_VAL || (r == 0 && m != 0))
		errno = ERANGE;
	return neg ? -r : r;
}

unsigned long strtoul(const char *s, char **end, int base)
{
	const char *p = s;
	while(isspace((unsigned char)*p))
		p++;
	int neg = 0;
	if(*p == '+' || *p == '-')
		neg = *p++ == '-';
	if((base == 0 || base == 16) && p[0] == '0' && (p[1] | 32) == 'x' &&
			isxdigit((unsigned char)p[2])){
		p += 2;
		base = 16;
	}
	if(base == 0)
		base = *p == '0' ? 8 : 10;
	unsigned long r = 0;
	int any = 0, over = 0;
	for(;; p++){
		int d;
		if(isdigit((unsigned char)*p))
			d = *p - '0';
		else if(isalpha((unsigned char)*p))
			d = (*p | 32) - 'a' + 10;
		else
			break;
		if(d >= base)
			break;
		if(r > (ULONG_MAX - d) / base)
			over = 1;
		r = r * base + d;
		any = 1;
	}
	if(end)
		*end = (char*)(any ? p : s);
	if(over){
		errno = ERANGE;
		return ULONG_MAX;
	}
	return neg ? -r : r;
}

/* ---- math.h */
typedef union { double d; uint64_t u; } bits;

double frexp(double x, int *e)
{
	bits v = {x};
	int ee = (int)((v.u >> 52) & 0x7ff);
	int adj = 0;
	if(ee == 0){
		if(x == 0){
			*e = 0;
			return x;
		}
		v.d = x * 18446744073709551616.0; /* 2^64 */
		ee = (int)((v.u >> 52) & 0x7ff);
		adj = 64;
	}
	if(ee == 0x7ff){
		*e = 0;
		return x;
	}
	*e = ee - 1022 - adj;
	v.u = (v.u & 0x800fffffffffffffull) | (0x3feull << 52);
	return v.d;
}

double ldexp(double x, int n)
{
	while(n > 1023){
		x *= 8.98846567431158e307; /* 2^1023 */
		n -= 1023;
		if(x == HUGE_VAL || x == -HUGE_VAL)
			return x;
	}
	while(n < -1022){
		x *= 2.2250738585072014e-308; /* 2^-1022 */
		n += 1022;
		if(x == 0)
			return x;
	}
	bits v;
	v.u = (uint64_t)(n + 1023) << 52;
	return x * v.d;
}

static const double LN2_HI = 6.93147180369123816490e-01;
static const double LN2_LO = 1.90821492927058770002e-10;

static double box_exp(double x)
{
	if(x != x)
		return x;
	if(x > 709.8)
		return HUGE_VAL;
	if(x < -745.2)
		return 0;
	const int k = (int)floor(x / (LN2_HI + LN2_LO) + 0.5);
	const double r = (x - k * LN2_HI) - k * LN2_LO;
	double term = 1, sum = 1;
	for(int i = 1; i < 18; i++){
		term *= r / i;
		sum += term;
	}
	return ldexp(sum, k);
}

static double box_log(double x)
{
	if(x != x || x < 0)
		return 0.0 / 0.0;
	if(x == 0)
		return -HUGE_VAL;
	if(x == HUGE_VAL)
		return x;
	int k;
	double m = frexp(x, &k);
	if(m < 0.70710678118654752440){
		m *= 2;
		k--;
	}
	const double f = (m - 1) / (m + 1), s = f * f;
	double term = f, sum = 0;
	for(int i = 1; i < 40; i += 2){
		sum += term / i;
		term *= s;
	}
	return 2 * sum + k * LN2_LO + k * LN2_HI;
}

double pow(double x, double y)
{
	if(y == 0 || x == 1)
		return 1;
	if(x != x || y != y)
		return x + y;
	if(y == floor(y) && fabs(y) < 2147483648.0){
		long n = (long)fabs(y);
		double r = 1, b = x;
		for(; n; n >>= 1, b *= b)
			if(n & 1)
				r *= b;
		return y < 0 ? 1 / r : r;
	}
	if(x < 0){
		if(y != floor(y))
			return 0.0 / 0.0;
		/* |y| past 2^31: even unless odd, and a double that large is even
		** from 2^53 on */
		const double r = box_exp(y * box_log(-x));
		return fmod(y, 2) != 0 ? -r : r;
	}
	if(x == 0)
		return y < 0 ? HUGE_VAL : 0;
	return box_exp(y * box_log(x));
}

double fmod(double x, double y)
{
	if(y == 0 || x != x || y != y || fabs(x) == HUGE_VAL)
		return 0.0 / 0.0;
	double ax = fabs(x);
	const double ay = fabs(y);
	while(ax >= ay){
		int ex, ey;
		frexp(ax, &ex);
		frexp(ay, &ey);
		double t = ldexp(ay, ex - ey);
		if(t > ax)
			t /= 2;
		ax -= t;
	}
	return x < 0 ? -ax : ax;
}

/* [KIT_BOX_TRIG] sin and cos: x less the nearest multiple of pi/2 (pi/2
** in three parts, fdlibm's, exact for |x| < 2^20 or so), a series on what
** is left (|r| <= pi/4, to r^19). The same wasm everywhere: the same
** results on the server and each client.
** simplified: no Payne-Hanek reduction, so far past 2^20 the result loses
** digits (a component's angles are small); musl's __rem_pio2 is the
** upgrade */
static const double PIO2_1 = 1.57079632673412561417e+00;
static const double PIO2_2 = 6.07710050630396597660e-11;
static const double PIO2_3 = 2.02226624871116645580e-21;

static double sin_kernel(double r)
{
	const double r2 = r * r;
	double term = r, sum = r;
	for(int i = 2; i < 20; i += 2){
		term *= -r2 / (i * (i + 1));
		sum += term;
	}
	return sum;
}

static double cos_kernel(double r)
{
	const double r2 = r * r;
	double term = 1, sum = 1;
	for(int i = 1; i < 20; i += 2){
		term *= -r2 / (i * (i + 1));
		sum += term;
	}
	return sum;
}

/* x's quadrant (0..3) and what is left in -pi/4..pi/4 */
static int reduce(double x, double *r)
{
	const double k = floor(x * 0.63661977236758134308 + 0.5);
	*r = ((x - k * PIO2_1) - k * PIO2_2) - k * PIO2_3;
	return (int)fmod(k, 4) & 3;
}

double sin(double x)
{
	if(x == 0)
		return x;
	if(x != x || fabs(x) == HUGE_VAL)
		return 0.0 / 0.0;
	double r;
	switch(reduce(x, &r)){
	case 0: return sin_kernel(r);
	case 1: return cos_kernel(r);
	case 2: return -sin_kernel(r);
	default: return -cos_kernel(r);
	}
}

double cos(double x)
{
	if(x != x || fabs(x) == HUGE_VAL)
		return 0.0 / 0.0;
	double r;
	switch(reduce(x, &r)){
	case 0: return cos_kernel(r);
	case 1: return -sin_kernel(r);
	case 2: return -cos_kernel(r);
	default: return sin_kernel(r);
	}
}

/* atan: |x| > 1 as pi/2 - atan(1/x), past tan(pi/12) as pi/6 +
** atan((x sqrt(3) - 1) / (sqrt(3) + x)), then a series (|t| < 0.27) */
double atan(double x)
{
	if(x != x || x == 0)
		return x;
	if(x < 0)
		return -atan(-x);
	if(x > 1)
		return 1.57079632679489661923 - atan(1 / x);
	double base = 0;
	if(x > 0.26794919243112270647){
		x = (x * 1.73205080756887729353 - 1) / (1.73205080756887729353 + x);
		base = 0.52359877559829887308;
	}
	const double x2 = x * x;
	double term = x, sum = 0;
	for(int i = 1; i < 40; i += 2){
		sum += term / i;
		term *= -x2;
	}
	return base + sum;
}

double atan2(double y, double x)
{
	const double PI = 3.14159265358979323846;
	if(x != x || y != y)
		return x + y;
	const int yneg = ((bits){y}.u >> 63) != 0;
	const int xneg = ((bits){x}.u >> 63) != 0;
	if(y == 0)
		return xneg ? (yneg ? -PI : PI) : y;
	if(x == 0)
		return yneg ? -PI / 2 : PI / 2;
	if(fabs(x) == HUGE_VAL){
		const double a = fabs(y) == HUGE_VAL ? PI / 4 : 0;
		const double r = xneg ? PI - a : a;
		return yneg ? -r : r;
	}
	if(fabs(y) == HUGE_VAL)
		return yneg ? -PI / 2 : PI / 2;
	const double a = atan(fabs(y / x));
	const double r = xneg ? PI - a : a;
	return yneg ? -r : r;
}

/* ---- locale.h */
static char g_point[] = ".";
static struct lconv g_lconv = {g_point};
struct lconv *localeconv(void){ return &g_lconv; }

/* ---- stdio.h: formatting. No file opens. */
FILE *stdin, *stdout, *stderr;
FILE *fopen(const char *p, const char *m){ (void)p; (void)m; return NULL; }
FILE *freopen(const char *p, const char *m, FILE *f)
{
	(void)p; (void)m; (void)f;
	return NULL;
}
int fclose(FILE *f){ (void)f; return EOF; }
int getc(FILE *f){ (void)f; return EOF; }
int ungetc(int c, FILE *f){ (void)c; (void)f; return EOF; }
size_t fread(void *p, size_t s, size_t n, FILE *f)
{
	(void)p; (void)s; (void)n; (void)f;
	return 0;
}
int ferror(FILE *f){ (void)f; return 1; }
int feof(FILE *f){ (void)f; return 1; }
int fflush(FILE *f){ (void)f; return 0; }
int fputs(const char *s, FILE *f){ (void)s; (void)f; return 0; }
int fprintf(FILE *f, const char *fmt, ...){ (void)f; (void)fmt; return 0; }

typedef struct { char *s; size_t n, len; } Out;

static void put(Out *o, char c)
{
	if(o->len + 1 < o->n)
		o->s[o->len] = c;
	o->len++;
}

static void puts_n(Out *o, const char *s, size_t n)
{
	for(size_t i = 0; i < n; i++)
		put(o, s[i]);
}

/* The P (1-17) significant digits of x > 0, rounded: *m with exactly P
** digits, x ~ m * 10^(e-P+1) */
static void sig_digits(double x, int P, uint64_t *m, int *e)
{
	int b;
	frexp(x, &b);
	int ex = (int)floor((b - 1) * 0.30102999566398120);
	const uint64_t lim = (uint64_t)P10[P];
	for(int i = 0; i < 8; i++){
		const double r = floor(scale10(x, P - 1 - ex) + 0.5);
		if(r >= (double)lim){
			ex++;
			continue;
		}
		if(r < (double)(lim / 10)){
			ex--;
			continue;
		}
		*m = (uint64_t)r;
		break;
	}
	*e = ex;
}

/* Digits of m (nd of them) into d */
static int digits_of(uint64_t m, int nd, char *d)
{
	for(int i = nd - 1; i >= 0; i--, m /= 10)
		d[i] = (char)('0' + m % 10);
	return nd;
}

/* x >= 0 as conversion c ('e', 'f' or 'g', lower case) with precision
** prec, alt the '#' flag; into buf (at least 400 bytes for 'f') */
static int fmt_double(double x, char c, int prec, int alt, char *buf)
{
	char d[24];
	int nd = 0, e = 0, n = 0;
	uint64_t m = 0;
	if(c == 'g' && prec == 0)
		prec = 1;
	if(x == 0){
		d[0] = '0';
		nd = 1;
		e = 0;
	}
	int fixed = c == 'f';
	int frac = prec; /* fraction digits */
	if(c == 'g'){
		const int P = prec > 17 ? 17 : prec;
		if(x != 0){
			sig_digits(x, P, &m, &e);
			nd = digits_of(m, P, d);
		}
		fixed = prec > e && e >= -4;
		frac = fixed ? prec - 1 - e : prec - 1;
	} else if(c == 'e'){
		const int P = prec + 1 > 17 ? 17 : prec + 1;
		if(x != 0){
			sig_digits(x, P, &m, &e);
			nd = digits_of(m, P, d);
		}
	} else if(x != 0){
		int e0;
		sig_digits(x, 17, &m, &e0);
		const int P = e0 + 1 + prec;
		if(P > 17){
			nd = digits_of(m, 17, d);
			e = e0;
		} else if(P <= 0){
			/* rounds to 0 or to one unit of the last place */
			const double r = floor(scale10(x, prec) + 0.5);
			d[0] = r >= 1 ? '1' : '0';
			nd = 1;
			e = r >= 1 ? -prec : 0;
		} else {
			sig_digits(x, P, &m, &e);
			nd = digits_of(m, P, d);
		}
	}
	if(fixed){
		/* the value is 0.d0d1... * 10^(e+1) */
		if(e < 0)
			buf[n++] = '0';
		for(int i = 0; i <= e; i++)
			buf[n++] = i < nd ? d[i] : '0';
		if(frac > 0 || alt)
			buf[n++] = '.';
		for(int i = 0; i < frac; i++){
			const int at = e + 1 + i;
			buf[n++] = at >= 0 && at < nd ? d[at] : '0';
		}
	} else {
		buf[n++] = d[0];
		if(frac > 0 || alt)
			buf[n++] = '.';
		for(int i = 1; i <= frac; i++)
			buf[n++] = i < nd ? d[i] : '0';
		buf[n++] = 'e';
		buf[n++] = e < 0 ? '-' : '+';
		const int ae = e < 0 ? -e : e;
		if(ae >= 100)
			buf[n++] = (char)('0' + ae / 100);
		buf[n++] = (char)('0' + ae / 10 % 10);
		buf[n++] = (char)('0' + ae % 10);
	}
	if(c == 'g' && !alt){
		/* trailing zeros of the fraction, and a bare point */
		int ep = 0;
		while(ep < n && buf[ep] != 'e')
			ep++;
		int dot = 0;
		while(dot < ep && buf[dot] != '.')
			dot++;
		if(dot < ep){
			int z = ep;
			while(z > dot + 1 && buf[z - 1] == '0')
				z--;
			if(z == dot + 1)
				z = dot;
			for(int i = ep; i < n; i++)
				buf[z + i - ep] = buf[i];
			n -= ep - z;
		}
	}
	return n;
}

int vsnprintf(char *s, size_t cap, const char *f, va_list ap)
{
	Out o = {s, cap, 0};
	for(; *f; f++){
		if(*f != '%'){
			put(&o, *f);
			continue;
		}
		f++;
		int left = 0, zero = 0, plus = 0, space = 0, alt = 0;
		for(;; f++){
			if(*f == '-') left = 1;
			else if(*f == '0') zero = 1;
			else if(*f == '+') plus = 1;
			else if(*f == ' ') space = 1;
			else if(*f == '#') alt = 1;
			else break;
		}
		int width = 0, prec = -1;
		if(*f == '*'){
			width = va_arg(ap, int);
			f++;
		} else {
			while(isdigit((unsigned char)*f))
				width = width * 10 + (*f++ - '0');
		}
		if(*f == '.'){
			f++;
			prec = 0;
			if(*f == '*'){
				prec = va_arg(ap, int);
				f++;
			} else {
				while(isdigit((unsigned char)*f))
					prec = prec * 10 + (*f++ - '0');
			}
		}
		int longs = 0;
		while(*f == 'l' || *f == 'h' || *f == 'z'){
			if(*f == 'l')
				longs++;
			f++;
		}
		char tmp[420];
		const char *body = tmp;
		int n = 0;
		char sign = 0;
		const char *prefix = "";
		int numeric = 1;
		const char c = *f;
		switch(c){
		case 'd': case 'i': {
			long long v = longs >= 2 ? va_arg(ap, long long) :
					longs ? (long long)va_arg(ap, long) : va_arg(ap, int);
			unsigned long long u = v < 0 ? -(unsigned long long)v : v;
			if(v < 0) sign = '-';
			else if(plus) sign = '+';
			else if(space) sign = ' ';
			char r[24];
			int k = 0;
			do { r[k++] = (char)('0' + u % 10); u /= 10; } while(u);
			while(k < prec)
				r[k++] = '0';
			if(prec == 0 && v == 0)
				k = 0;
			while(k)
				tmp[n++] = r[--k];
			break; }
		case 'u': case 'x': case 'X': case 'o': case 'p': {
			unsigned long long u = c == 'p' ? (uintptr_t)va_arg(ap, void*) :
					longs >= 2 ? va_arg(ap, unsigned long long) :
					longs ? (unsigned long long)va_arg(ap, unsigned long) :
					va_arg(ap, unsigned int);
			const int base = c == 'o' ? 8 : c == 'u' ? 10 : 16;
			const char *dig = c == 'X' ? "0123456789ABCDEF" :
					"0123456789abcdef";
			if((alt && u && base == 16) || c == 'p')
				prefix = c == 'X' ? "0X" : "0x";
			char r[24];
			int k = 0;
			const unsigned long long u0 = u;
			do { r[k++] = dig[u % base]; u /= base; } while(u);
			if(alt && base == 8 && r[k - 1] != '0')
				r[k++] = '0';
			while(k < prec)
				r[k++] = '0';
			if(prec == 0 && u0 == 0 && !(alt && base == 8))
				k = 0;
			while(k)
				tmp[n++] = r[--k];
			break; }
		case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': {
			double v = va_arg(ap, double);
			if(v < 0 || (v == 0 && 1 / v < 0)){
				sign = '-';
				v = -v;
			} else if(plus)
				sign = '+';
			else if(space)
				sign = ' ';
			const int upper = c == 'E' || c == 'G' || c == 'F';
			if(v != v || v == HUGE_VAL){
				const char *t = v != v ? (upper ? "NAN" : "nan") :
						(upper ? "INF" : "inf");
				n = 3;
				memcpy(tmp, t, 3);
				zero = 0;
				break;
			}
			if(prec < 0)
				prec = 6;
			if(prec > 300)
				prec = 300;
			if((c == 'f' || c == 'F') && v >= 1e100){
				/* simplified: past 1e100 'f' prints as 'e' (a buffer
				** of its own for 300 integer digits is the upgrade) */
				n = fmt_double(v, 'e', prec, alt, tmp);
			} else {
				n = fmt_double(v, (char)(c | 32), prec, alt, tmp);
			}
			if(upper)
				for(int i = 0; i < n; i++)
					tmp[i] = (char)toupper(tmp[i]);
			break; }
		case 'c':
			tmp[n++] = (char)va_arg(ap, int);
			numeric = 0;
			break;
		case 's': {
			const char *str = va_arg(ap, const char*);
			if(!str)
				str = "(null)";
			size_t k = 0;
			while(str[k] && (prec < 0 || (int)k < prec))
				k++;
			body = str;
			n = (int)k;
			numeric = 0;
			break; }
		case '%':
			tmp[n++] = '%';
			numeric = 0;
			break;
		default:
			/* unknown: written as it is */
			put(&o, '%');
			if(!*f)
				f--;
			else
				put(&o, *f);
			continue;
		}
		const int plen = (int)strlen(prefix);
		const int total = n + (sign ? 1 : 0) + plen;
		int pad = width > total ? width - total : 0;
		if(!left && !(zero && numeric))
			for(; pad > 0; pad--)
				put(&o, ' ');
		if(sign)
			put(&o, sign);
		puts_n(&o, prefix, plen);
		if(!left && zero && numeric)
			for(; pad > 0; pad--)
				put(&o, '0');
		puts_n(&o, body, n);
		for(; pad > 0; pad--)
			put(&o, ' ');
	}
	if(cap)
		s[o.len < cap ? o.len : cap - 1] = 0;
	return (int)o.len;
}

int snprintf(char *s, size_t n, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	const int r = vsnprintf(s, n, fmt, ap);
	va_end(ap);
	return r;
}

int sprintf(char *s, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	/* simplified: unbounded, as sprintf is; Lua sizes its buffers */
	const int r = vsnprintf(s, (size_t)INT_MAX, fmt, ap);
	va_end(ap);
	return r;
}
