namespace NS {
class C {
 public:
  void m() { if (x) { y(); } }
  int k;
};
}
struct S { int a; } gvar;
static int f(void) { return 1; }
int g(int a)
{
  return a;
}
