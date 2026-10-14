#include <QApplication>
#include <QLabel>

int main(int argc, char **argv)
{
  QApplication app(argc, argv);
  QLabel label(QStringLiteral("Hello from a cmake-dep binary package (Qt %1)").arg(QT_VERSION_STR));
  label.setMargin(24);
  label.show();
  return app.exec();
}
