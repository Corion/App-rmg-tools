# Release Manager Progress Dashboard

This monitors the progress through the Perl Release Managers Guide in a
console window. Output as a data structure for a web page is planned but not
yet implemented.

# Example output

```
Previous release is 5.35.0, our version will be 5.35.1
Your name in Porting/release_schedule.pod is Max Maischein
CPAN modules newer than blead
Module           Perl                                     CPAN
Data::Dumper     XSAWYERX/Data-Dumper-2.173.tar.gz        NWCLARK/Data-Dumper-2.180.tar.gz
Encode           DANKOGAI/Encode-3.08.tar.gz              DANKOGAI/Encode-3.10.tar.gz
experimental     LEONT/experimental-0.022.tar.gz          LEONT/experimental-0.024.tar.gz
Module::CoreList BINGOS/Module-CoreList-5.20210520.tar.gz BINGOS/Module-CoreList-5.20210521.tar.gz
Test::Simple     EXODIST/Test-Simple-1.302183.tar.gz      EXODIST/Test-Simple-1.302185.tar.gz
version          LEONT/version-0.9928.tar.gz              LEONT/version-0.9929.tar.gz

[ ] Release branch created
[✓] Configure was run
[ ] Perl 5.35.1 was built
[✓] make test was run
[ ] Module::CoreList was updated
[ ] perldelta was finalized for 5.35.1
[ ] perldelta is clean
[ ] tag for v5.35.1 is created
[ ] release tarball exists
[ ] local installation of 5.35.1 exists at /tmp/perl-5.35.1
[ ] release tarball published for testing
[ ] release tarball published on CPAN
[ ] Release schedule ticked and committed
[ ] Release branch merged back to blead
[ ] Release tag pushed upstream
[ ] Version number bumped for next dev release
```
