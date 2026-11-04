/* [KIT] The Kit box's libc (../libc.c): what Lua 5.1 uses and no more.
** Every standard header of this directory includes this one. Files never
** open (lauxlib's luaL_loadfile is compiled, never reached); the locale is
** C's; ctype is ASCII. */
#pragma once
#include <stddef.h>
#include <stdarg.h>

/* string.h */
void *memcpy(void *d, const void *s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
void *memchr(const void *s, int c, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
int strcoll(const char *a, const char *b);
char *strcpy(char *d, const char *s);
char *strncpy(char *d, const char *s, size_t n);
char *strcat(char *d, const char *s);
char *strncat(char *d, const char *s, size_t n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *h, const char *n);
char *strpbrk(const char *s, const char *a);
size_t strspn(const char *s, const char *a);
size_t strcspn(const char *s, const char *a);
char *strerror(int e);

/* stdlib.h */
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
void *malloc(size_t n);
void *realloc(void *p, size_t n);
void free(void *p);
double strtod(const char *s, char **end);
unsigned long strtoul(const char *s, char **end, int base);
void exit(int status) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
int abs(int x);

/* stdio.h */
#define EOF (-1)
#define BUFSIZ 512
typedef struct box_FILE FILE;
extern FILE *stdin, *stdout, *stderr;
int sprintf(char *s, const char *fmt, ...);
int snprintf(char *s, size_t n, const char *fmt, ...);
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap);
FILE *fopen(const char *p, const char *m);
FILE *freopen(const char *p, const char *m, FILE *f);
int fclose(FILE *f);
int getc(FILE *f);
int ungetc(int c, FILE *f);
size_t fread(void *p, size_t s, size_t n, FILE *f);
int ferror(FILE *f);
int feof(FILE *f);
int fflush(FILE *f);
int fputs(const char *s, FILE *f);
int fprintf(FILE *f, const char *fmt, ...);

/* ctype.h */
int isalpha(int c);
int isdigit(int c);
int isalnum(int c);
int isspace(int c);
int iscntrl(int c);
int islower(int c);
int isupper(int c);
int ispunct(int c);
int isxdigit(int c);
int isprint(int c);
int isgraph(int c);
int tolower(int c);
int toupper(int c);

/* math.h */
#define HUGE_VAL __builtin_huge_val()
#define floor(x) __builtin_floor(x)
#define ceil(x) __builtin_ceil(x)
#define sqrt(x) __builtin_sqrt(x)
#define fabs(x) __builtin_fabs(x)
double pow(double x, double y);
double fmod(double x, double y);
double frexp(double x, int *e);
double ldexp(double x, int e);
double sin(double x);
double cos(double x);
double atan(double x);
double atan2(double y, double x);

/* locale.h */
struct lconv { char *decimal_point; };
struct lconv *localeconv(void);

/* errno.h */
extern int errno;
#define ERANGE 34

/* assert.h */
#define assert(x) ((void)0)
