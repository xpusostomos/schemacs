struct S { int a; } gvar;
static int f(void) { return 1; }
int g(int a)
{
  if (a > 0)
    {
      return a;
    }
  return 0;
}
