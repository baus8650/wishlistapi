# Apple purchase-verification roots

Public DER root certificates from [Apple PKI](https://www.apple.com/certificateauthority/), checked September 7, 2026. These are public trust anchors, not signing keys or secrets. The supplied AppleIncRootCertificate.cer was compared byte-for-byte with Apple's published download.

| File | Official source | SHA-256 |
| --- | --- | --- |
| AppleIncRootCertificate.cer | https://www.apple.com/appleca/AppleIncRootCertificate.cer | B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024 |
| AppleRootCA-G2.cer | https://www.apple.com/certificateauthority/AppleRootCA-G2.cer | C2B9B042DD57830E7D117DAC55AC8AE19407D38E41D88F3215BC3A890444A050 |
| AppleRootCA-G3.cer | https://www.apple.com/certificateauthority/AppleRootCA-G3.cer | 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179 |

The existing Docker resource-staging step includes this directory read-only in the runtime image. Docker sets `APPLE_ROOT_CERTIFICATE_PATHS` to the three `/app/Resources/AppleCertificates/` paths. For non-Docker runs, supply absolute paths to these files through the same environment variable.

When updating trust anchors, obtain replacements only from Apple's official PKI site and review changes to this file and the Docker environment variable together.
