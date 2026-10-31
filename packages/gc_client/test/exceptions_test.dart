import 'package:gc_client/gc_client.dart';
import 'package:test/test.dart';

void main() {
  test('failureClassOf: transient for a GcTransportException, hard for '
      'anything else', () {
    expect(
      failureClassOf(const GcTransportException('gc bd show x exited 4')),
      FailureClass.transient,
    );
    expect(
      failureClassOf(const GcRefusal('gc bd show x exited 1')),
      FailureClass.hard,
    );
    expect(failureClassOf(StateError('boom')), FailureClass.hard);
    expect(failureClassOf(null), FailureClass.hard);
  });
}
