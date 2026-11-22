class C { public: int m; };
struct S { int a; double b; };
namespace N { class D : public C { void f(); }; }
int (*fp)(int, char);
void (*signal(int, void (*)(int)))(int);
int arr[10];
int x = f(1), y = 2;
int xx = {1, 2};
auto lam = [](int x) { return x; };
template <typename T> requires C<T> struct R {};
void req(int x) requires (N > 0);
auto g() requires requires (T t) { t.foo(); };
T operator+(T a, T b);
Foo::Foo(int a) : x_(a), y_{1, 2}, z_(3) {}
std::map<std::string, int> m;
int *p1, **p2;
typedef int (*fptr)(void);
int a __attribute__((unused));
struct T { int x : 3, y : 5; };
