int foo (bar, baz, yuk)
     int bar [];
     int (*baz) (my_type);
     int (*(* yuk) (void)) (void);
{
  return bar[baz] + yuk;
}

static int
simple (void)
{
  return 0;
}

int qux (a)
     int a;
{
  return a;
}
