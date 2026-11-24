#include <stdio.h>
/* A block comment. It has two sentences.
   Another sentence here.  */
static int g (int a)
{
  // A line comment. With a sentence.
  const char *s = "A string. With two sentences. \
continued here.";
#if FOO
  if (a) { return 1; }
#else
  a = 2; // done
#endif
  switch (a) {
  case 1: a++; break;
  default: a--;
  }
  return a;
}
