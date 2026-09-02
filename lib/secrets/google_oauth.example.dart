/// Google OAuth 凭据模板。
///
/// **重要：复制这个文件成 `google_oauth.dart`，填入你的凭据，然后 `google_oauth.dart`
/// 会被 .gitignore 忽略而不会提交。**
///
/// 有两种方式取凭据：
///
/// 1. **使用内嵌的 gemini-cli 凭据（默认）**
///    —— 保持下面的 `bundled` 定义不变即可。
///    这些凭据是 Google 随 gemini-cli 分发的公开客户端，不是秘密。
///    但 Google 可以随时吊销它，届时所有人的登录会同时失效。
///
/// 2. **使用自己注册的 Google Cloud 项目**
///    —— 在 Google Cloud Console 建一个"桌面应用"客户端，
///    复制其 Client ID 和 Client Secret，替换下面的值。
///    这样你的登录不会被别人的吊销牵连。
///
/// 找不到这些值时，app 会回落到 gemini-cli 的内嵌凭据。
library;

const googleOAuthClientId =
    '681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com';

const googleOAuthClientSecret = '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';
