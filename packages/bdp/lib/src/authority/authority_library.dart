/// The BDP authority: one Scope (Transactional subset) over SQLite.
///
/// Every exported name carries the `Authority` prefix (or is a member of
/// [ScopeAuthority]), so the authority and the client share `bdp.dart`
/// without colliding. The SQLite store is not exported: current state
/// changes only through a [ScopeAuthority] mutation.
library;

import 'authority.dart';

export 'authority.dart'
    show
        AuthorityNotAdmitted,
        AuthorityRead,
        AuthorityReceipt,
        ScopeAuthority,
        authorityAnonymousPrincipal,
        authorityViewToken;
export 'authority_scope.dart' show AuthorityScope;
export 'http.dart' show authorityHandler;
export 'identity.dart' show AuthorityResourceKind;
export 'problem.dart' show AuthorityProblem;
export 'types.dart'
    show
        AuthorityEndpointConstraint,
        AuthorityTypeDescriptor,
        AuthorityTypeRegistry,
        AuthorityTypeRevision,
        authorityTypeRevisionOf;
