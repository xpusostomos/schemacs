namespace NS {
/* A namespace comment. Two sentences here.
   The second line.  */
class C {
 public:
  // A method comment. One more sentence.
  int m (int a)
  {
    return a; // trailing
  }
};
}
#if 0
int h (void)
{
  return 0;
}
#elif 1
int k (void) { return 1; }
#endif
