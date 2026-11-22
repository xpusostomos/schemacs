struct Point { int x, y; };
Point p{1, 2};
Point q = {3, 4};
std::vector<int> v = {1, 2, 3};
Foo f{};
int arr[] = {1, 2};
void g() { auto l = [](int a) { return a; }; }
enum class E { A, B };
enum struct F : int { C, D };
struct G : Base { int z; };
