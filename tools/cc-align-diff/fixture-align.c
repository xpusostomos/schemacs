/* The line-up fixture (C). Both harnesses locate positions by the
   needles the case table names, so every needle is unique. */

int assign_one (int a, int b, int c)
{
  int result = a + b
    + c;
  result = result
    = 2;
  return result;

}

int chain (int offset)
{
  result = proc->add (17)->add (18)
    ->add (19) + offset;
  return result;
}

void strings (char *prefix)
{
  result = prefix + "A message "
    "string.";
}

int ternary (int arg)
{
  return arg % 2 == 0 ? arg / 2
    : (3 * arg + 1);
}

void call (int a, int b)
{
  foo (xyz, aaa + bbb + ccc
       + ddd + eee + fff);
  bar (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
       b);
  if (x < 10
      || at_limit (x,
                   list))
    ;
}

void bare (void)
{
  {m+=n; n=0;}
}

void multiblock (void)
{
  int *foo[] = {
    { 17,
      18
    }
  };
}

void runin (void)
{ puts ("Hello world!");
  return;
}

int main ()
/* This is the main function. */
{
  return 0;
}

/* A comment
   * continuation
   */

void gcc_asm (int w, int x, int y)
{
  asm ("foo %1, %0\n"
       : "=r" (w),
         "=r" (x)
       :  "0" (y));
}

int throws (void) throws Cyphr,
  Bar,
  Vlod
{
  return 0;
}

void looping (void)
{
  do
    {
      x++;
    }
  while (x < 10);
}

void objcish (void)
{
  [foo blahBlah: fred
       barBaz: barney];
}
