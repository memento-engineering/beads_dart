// A build that administers the authority it is handed, or sends a request
// to it in process. Every marked line is a lint error; no other line may be.
import 'package:bdp/bdp.dart' show ScopeAuthority, authorityHandler;
import 'package:bdp/testing.dart' show HandlerClient;
import 'package:http/http.dart' as http;
import 'package:genesis_tree/genesis_tree.dart'
    show BuildContext, Component, MultiChildComponent, StatelessComponent;

/// Acts on an authority from its build, beside reads that act on nothing.
final class AdministersInBuild extends StatelessComponent {
  const AdministersInBuild(this.authority);

  final ScopeAuthority authority;

  @override
  Component build(BuildContext context) {
    // LINT: effects_only_in_leaves
    authority.reinitialize();
    // LINT: effects_only_in_leaves
    authority.close();
    // LINT: effects_only_in_leaves
    authority.installType(const {
      'id': 'https://station.test/types/note',
      'name': 'note',
      'describes': 'bead',
    });
    // LINT: effects_only_in_leaves
    authority.mutate('delete-bead', const {}, idempotencyKey: 'k');
    // LINT: effects_only_in_leaves
    authority.watch();
    // LINT: effects_only_in_leaves
    authority.snapshotDocument();
    final client = HandlerClient(authorityHandler(authority));
    // LINT: effects_only_in_leaves
    client.send(http.Request('POST', Uri.parse('http://scope.test/m')));
    authority.observe();
    authority.changePage(startNow: true);
    authority.resource('beads/a');
    return const _Nothing();
  }
}

/// A component with no children.
final class _Nothing extends MultiChildComponent {
  const _Nothing() : super(children: const []);
}
