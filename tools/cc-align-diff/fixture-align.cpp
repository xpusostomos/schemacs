/* The line-up fixture (C++). */

template <typename T,
	  typename U>
struct Pair {};

void lambdas (int n)
{
  auto f = [&] (int x) {
    return x + n;
  };
}

void templates (void)
{
  foo<int,
      char> (1);
}

void set_lines (void)
{
  set_line (line_t {point_t{0.4, 0.2},
		    point_t{0.2, 0.5},
		    point_t{0.1, 0.9}});
}

struct STR2 {
  int i; float f;
} str_3 = {1, 1.7},
  str_4 = {2,
	   3.1
  };

class K {
public:
  void one (void) { return; }
};
