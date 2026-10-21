## evidence_id

ev_230f795c0f427c3518c73817146f2affb797a7e4fd6feee7d0f072562e9c8867

## subject.name

files-recovery-free-android.apk

## subject.digest

| Key    | Value                                                            |
|--------|------------------------------------------------------------------|
| sha256 | 8a6239810911f79bf3871b96d56282c6a5bdab7d85b63bc2cb011d23aee1087b |

## subject.local_path

/home/z/my-project/download/rea_evidence/files-recovery-free-android.apk

## subject.format

apk

## subject.architecture

null

## provider

| Key     | Value                        |
|---------|------------------------------|
| id      | flutter                      |
| name    | Flutter build identification |
| version | null                         |

## analysis_profile

null

## predicate_type

rea.analysis

## operation

identify_flutter_build

## parameters

| Key  | Value                                                                    |
|------|--------------------------------------------------------------------------|
| path | /home/z/my-project/download/rea_evidence/files-recovery-free-android.apk |

## raw_result

null

## normalized_result.target

| Key    | Value                                                                    |
|--------|--------------------------------------------------------------------------|
| path   | /home/z/my-project/download/rea_evidence/files-recovery-free-android.apk |
| bytes  | 50998225                                                                 |
| sha256 | 8a6239810911f79bf3871b96d56282c6a5bdab7d85b63bc2cb011d23aee1087b         |

## normalized_result.flutter_detected

true

## normalized_result.abis

| abi         | libapp          | libflutter      |
|-------------|-----------------|-----------------|
| arm64-v8a   | [object Object] | [object Object] |
| armeabi-v7a | [object Object] | [object Object] |
| x86_64      | [object Object] | [object Object] |

## normalized_result.coverage

partial

## confidence

observed

## authority

shipped-artifact

## environment

null

## limitations

The APK is read through an owned read-only snapshot; concurrent changes to the original cannot mix into this observation,The snapshot hash identifies a Dart SDK build only against an external mapping dataset; REA performs no lookup,Release engine builds often carry no labeled Dart version string; absence is reported, not guessed,Engine build IDs come only from ELF-declared PT_NOTE/SHT_NOTE records; conflicting or incompletely examined notes preserve candidates and report partial coverage,The snapshot hash sits 20 bytes after each snapshot magic in the AOT payload; findings are observations of that layout,ELF header validity checks the supported header layout and declared table extents; identification does not resolve symbols or validate table contents,lib/arm64-v8a/libapp.so carries 1 snapshot section(s); a complete AOT payload carries two, so the library is truncated or nonstandard,lib/armeabi-v7a/libapp.so carries 1 snapshot section(s); a complete AOT payload carries two, so the library is truncated or nonstandard,lib/x86_64/libapp.so carries 1 snapshot section(s); a complete AOT payload carries two, so the library is truncated or nonstandard

## relationship_coverage

null

## locations

| kind          | path                                                                     |
|---------------|--------------------------------------------------------------------------|
| artifact-path | /home/z/my-project/download/rea_evidence/files-recovery-free-android.apk |

## evidence_links

