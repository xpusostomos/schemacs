int main (int argc, char **argv)
{
  int i;
  if (argc > 1)
    return 1;
  else
    i = 0;
  switch (i)
    {
    case 0:
      break;
    default:
      i++;
    }
  for (i = 0; i < argc; i++)
    {
      printf ("%s\n", argv[i]);
    }
  return 0;
}
