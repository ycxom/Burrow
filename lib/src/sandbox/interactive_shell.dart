/// Selects the command used by Burrow's user-facing interactive terminal.
library;

import 'dart:io';

/// Chooses the best login shell already present in [rootfs].
///
/// Termux uses the same shape of policy: walk a short preference list and use
/// `sh` only as the final fallback. That distinction matters on Ubuntu, where
/// `/bin/sh` is dash and deliberately has no interactive Tab completion even
/// though `/bin/bash` is already available.
///
/// We intentionally do not copy Termux's leading `login` candidate. Its
/// `login` is a Termux-specific session wrapper; a distro's `/bin/login` would
/// ask for credentials instead of opening the user's terminal.
Future<String> interactiveShellCommand(Directory? rootfs) async {
  if (rootfs == null) return 'exec sh';

  const candidates = <String>[
    '/bin/bash',
    '/usr/bin/bash',
    '/bin/zsh',
    '/usr/bin/zsh',
    '/bin/fish',
    '/usr/bin/fish',
    '/bin/ash',
    '/bin/sh',
  ];
  for (final candidate in candidates) {
    if (await File('${rootfs.path}$candidate').exists()) {
      return 'exec $candidate -l';
    }
  }

  // A valid distro is required to provide /bin/sh. Keeping this fallback even
  // for a damaged fixture lets the shell itself produce the useful error.
  return 'exec /bin/sh -l';
}
