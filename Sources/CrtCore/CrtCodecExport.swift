// The Digital video stage's codec lives in its own module so it can be
// compiled optimized even in debug builds (see Package.swift); everything
// that imports CrtCore sees it.
@_exported import CrtCodec
