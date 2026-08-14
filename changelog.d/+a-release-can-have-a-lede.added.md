A `note` fragment type, for the paragraph that frames a release rather than an
entry in it. Towncrier renders types in declaration order and `note` is
declared first, so it lands above `### Added` with no template fork and
retires itself on fold like any other fragment.
