int g(int x)
{
  int a = 0;
top:
  switch (x)
    {
    case 1:
      a = 1;
      break;
    case 2:
    default:
      goto top;
    }
done:
  return a;
}
