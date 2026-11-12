# Security Policy

## Secrets and Tokens

Do not store GitHub tokens, passwords, API keys, or credentials directly inside PowerShell scripts.

Use environment variables instead:

```powershell
$GitHubToken = $env:GITHUB_TOKEN
```

To configure the token on Windows:

```powershell
setx GITHUB_TOKEN "your_github_token_here"
```

After running `setx`, close and reopen PowerShell so the new environment variable is available.

## If a Token Was Committed

If a GitHub token was accidentally committed to the repository:

1. Revoke the token immediately in GitHub.
2. Generate a new token.
3. Update the local environment variable.
4. Remove the token from the script.
5. Avoid reusing the exposed token.

## Recommended Token Permissions

Use the minimum permissions required for the project.

Keep the update file and the reports in separate repositories. Locations download the update file without a token; the token they use should only be able to write to the report repository (for example, a fine-grained token with Contents: Read and write on that repository alone). A token that can write to the update repository could replace the file and its checksum for every location.

Avoid using personal tokens with broad account-level permissions.

## Sensitive Data

Do not publish:

- passwords
- tokens
- private location details
- customer information
- internal network paths
- confidential database content
- private business data

