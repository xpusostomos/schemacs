class Q : public QObject {
  Q_OBJECT
public slots:
  void f();
signals:
  void g();
private:
  int m;
};
