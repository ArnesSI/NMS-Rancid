# This file is part of NMS::Rancid Perl module.

use ExtUtils::MakeMaker;

WriteMakefile(
	NAME            => 'NMS::Rancid',
	VERSION_FROM    => 'lib/NMS/Rancid.pm',

	dist => {
		COMPRESS => 'gzip',
		SUFFIX => '.gz',
	},
);