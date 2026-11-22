namespace N { template <class T> class V {}; }
std::vector<int> v;
Foo<Bar<Baz> > x;
A<B>::C y;
int z;
unsigned long long w;
static const char *p;
struct s { int m; } q;
struct s *r;
typedef struct { int a; } anon_t;
enum { RED, GREEN } colour;
_BitInt(32) big;
typeof (x) tx;
auto a1 = 1;
decltype(v) d;
template <typename T, int N> struct Arr {};
V<int> f(V<int> arg);
x < y > z;
if (a < b && c > d) {}
std::map<std::string, int> m;
Foo<T>::bar<U> baz;
