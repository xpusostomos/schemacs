/* A short comment. */
int a;

/* This is a long block comment which should be filled when point is
   inside it, because it is wider than seventy characters and this line
   is part of a paragraph. */
int b;

int c; /* trailing comment which is long enough that filling it will
          wrap the text onto another line and keep the prefix */
int d;

/*
 * A star-prefixed comment.
 * Second line of it.
 */
int e;

/* foo bar */
int f;

/**
 * A doc comment with a sentence.  Two spaces after it here.
 * More text.
 */
int g;

int h; /* one */
int i; /*

          an empty first line */
int j;

int k; // a line comment which is long enough that auto filling would
       // break it into two lines with the same prefix
// another line comment that is quite long and should be broken when
// filled

char *s = "a long string literal that is inside a string and should \
be filled as a paragraph of its own when point is in it";

#define M(x) \
  do { x; } while (0)

int l; /* ender hangs off the end of the last line of text here */
