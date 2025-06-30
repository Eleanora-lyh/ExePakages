[CmdletBinding()]
param(
    [string]$RooVersion,
    [string]$AiCoderToolsVersion,
    [string]$RooUrl,
    [string]$AiCoderToolsUrl,
    [string]$OllamaModel = "all-minilm",
    [switch]$forceInit, # Force initialize everything, bypass existence checks
    [switch]$enableExperimentalTools = $false, # Enable installation of experimental tools like Ollama
    [switch]$preRelease = $false # Use pre-release versions if available
)

# Function to check if running as administrator
function Test-Administrator {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($user)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# Common exit function that keeps terminal open if running as admin
function Exit-Script {
    param (
        [int]$ExitCode = 0
    )
    if (Test-Administrator) {
        Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow -NoNewline
        Read-Host
    }
    exit $ExitCode
}

# Function to check GitHub CLI authentication
function Test-GitHubAuth {
    param (
        [switch]$forceInit
    )
    Write-Host "`n=== Checking GitHub Authentication ===" -ForegroundColor Cyan
    try {
        # Check if gh CLI is installed
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Write-Error "GitHub CLI (gh) is not installed. Please install it from: https://cli.github.com/"
            return $false
        }

        # Check authentication status
        $authStatus = gh auth status 2>&1
        if ($LASTEXITCODE -eq 0 -and -not $forceInit) {
            Write-Host "✓ GitHub authentication is configured" -ForegroundColor Green
            return $true
        }

        Write-Host "→ GitHub authentication with your <alias>_microsoft account is required. Please login with your Microsoft account..." -ForegroundColor Yellow
        Write-Host "  (e.g., if your alias is 'johndoe', use 'johndoe_microsoft' account)" -ForegroundColor Gray
        # Start browser-based authentication
        gh auth login --web
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ GitHub authentication successful" -ForegroundColor Green
            return $true
        }
        
        Write-Error "GitHub authentication failed"
        return $false
    }
    catch {
        Write-Error "Error checking GitHub authentication: $_"
        return $false
    }
}

# Function to download file with progress
function Download-File {
    param(
        [string]$Url,
        [string]$OutFile,
        [switch]$forceDownload = $forceInit
    )
    Write-Host "`n=== Downloading $OutFile with forceDownload: $forceDownload ===" -ForegroundColor Cyan
    try {
        Write-Host "→ Downloading from $Url..." -ForegroundColor Gray
        
        # Display extra info for debugging if it's a GitHub URL
        if ($Url -like "*github.com*/releases/download/*") {
            if ($Url -match '/download/([^/]+)/([^/]+)$') {
                $tagFromUrl = $matches[1]
                $fileFromUrl = $matches[2]
                Write-Host "→ URL details: Tag = $tagFromUrl, File = $fileFromUrl" -ForegroundColor Gray
            }
        }
        # For GitHub URLs, use gh release download
        if ($Url -like "*github.com*/releases/download/*") {
            # Check if file exists and not forcing redownload
            if ((Test-Path $OutFile) -and -not $forceDownload) {
                Write-Host "→ File exists, using cached version" -ForegroundColor Yellow
                return $true
            }

            # Extract repository from URL (e.g., "ai-microsoft/Roo-Cline")
            if (-not ($Url -match 'github\.com/([^/]+/[^/]+)/')) {
                Write-Error "Invalid GitHub URL format: $Url"
                return $false
            }
            $repo = $matches[1]
            
            # Extract release tag from URL (e.g., "v0.0.7" or "v0.0.7-preview")
            if (-not ($Url -match 'download/([^/]+)/')) {
                Write-Error "Invalid GitHub release URL format: $Url"
                return $false
            }
            $releaseTag = $matches[1]
            
            Write-Host "→ Repository: $repo" -ForegroundColor Gray
            Write-Host "→ Release Tag: $releaseTag" -ForegroundColor Gray

            # Build and execute gh CLI command
            $filePattern = $OutFile
            
            # Handle prerelease files - often the release tag has "-preview" but the file doesn't
            if ($releaseTag -like "*-preview*" -and $OutFile -notlike "*-preview*") {
                # The release tag contains "-preview" but our OutFile doesn't, keep as is
            }
            elseif ($releaseTag -like "*-preview*" -and $OutFile -like "*-preview*") {
                # The release tag contains "-preview" and so does our OutFile, but the actual file might not
                $filePattern = $OutFile -replace "-preview", ""
                Write-Host "→ Adjusting pattern for prerelease: $filePattern" -ForegroundColor Gray
            }
            
            $ghCommand = "gh release download $releaseTag --repo $repo --pattern $filePattern"
            if ($forceDownload) {
                $ghCommand += " --clobber"
            }

            Write-Host "→ Executing: $ghCommand" -ForegroundColor Gray
            $output = Invoke-Expression "$ghCommand 2>&1"
            # Check if download was successful
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Download completed successfully" -ForegroundColor Green
                return $true
            }
            else {
                Write-Error "Failed to download with error $output"
                return $false
            }
        } else {

            if ((Test-Path $OutFile) -and -not $forceDownload) {
                Write-Host "→ File exists, using cached version" -ForegroundColor Yellow
                return $true
            }
                        
            Invoke-WebRequest -Uri $Url -OutFile $OutFile
            Write-Host "Successfully downloaded $OutFile"
            return $true
        }
    }
    catch {
        Write-Error "Failed to download $OutFile : $_"
        return $false
    }
}

# Function to get latest release version and URL from GitHub
function Get-LatestRelease {
    param(
        [string]$repo,
        [string]$assetPattern,
        [bool]$retried = $false,
        [bool]$includePreRelease = $preRelease
    )
    if ($includePreRelease) {
        Write-Host "→ Fetching releases (including prereleases) for $repo..." -ForegroundColor Gray
    } else {
        Write-Host "→ Fetching latest stable release info for $repo..." -ForegroundColor Gray
    }
    
    try {
        # Get release info based on whether we want prereleases
        $releaseInfo = $null
        if ($includePreRelease) {
            $releaseInfo = gh api "repos/$repo/releases" 2>&1
            if ($LASTEXITCODE -ne 0) {
                if (-not $retried -and $releaseInfo -match "404|Not Found") {
                    Write-Host "→ Access denied, attempting to re-authenticate..." -ForegroundColor Yellow
                    if (Test-GitHubAuth -forceInit) {
                        return Get-LatestRelease -repo $repo -assetPattern $assetPattern -retried $true -includePreRelease $includePreRelease
                    }
                }
                throw "Failed to fetch releases info: $releaseInfo"
            }
            
            $releases = $releaseInfo | ConvertFrom-Json
            # Get the first release (which is the newest) that has matching assets
            foreach ($release in $releases) {
                $asset = $release.assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1
                if ($asset) {
                    $version = $release.tag_name -replace '^v', ''
                    $isPrerelease = $release.prerelease
                    
                    # Also log the asset name to help with debugging
                    Write-Host "→ Found asset: $($asset.name) for version $version" -ForegroundColor Gray
                    
                    if ($isPrerelease) {
                        Write-Host "✓ Found prerelease version $version" -ForegroundColor Green
                    } else {
                        Write-Host "✓ Found stable version $version" -ForegroundColor Green
                    }
                    
                    return @{
                        Version = $version
                        Url = $asset.browser_download_url
                        IsPrerelease = $isPrerelease
                    }
                }
            }
            
            throw "No matching asset found in any release"
        } else {
            # Original code for stable releases only
            $releaseInfo = gh api "repos/$repo/releases/latest" 2>&1
            if ($LASTEXITCODE -ne 0) {
                if (-not $retried -and $releaseInfo -match "404|Not Found") {
                    Write-Host "→ Access denied, attempting to re-authenticate..." -ForegroundColor Yellow
                    if (Test-GitHubAuth -forceInit) {
                        return Get-LatestRelease -repo $repo -assetPattern $assetPattern -retried $true -includePreRelease $includePreRelease
                    }
                }
                throw "Failed to fetch release info: $releaseInfo"
            }
            
            $releaseInfo = $releaseInfo | ConvertFrom-Json
            $version = $releaseInfo.tag_name -replace '^v', ''
            
            # Get asset URL matching pattern
            $asset = $releaseInfo.assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1
            if (-not $asset) {
                throw "No matching asset found in latest release"
            }
            
            Write-Host "✓ Found stable version $version" -ForegroundColor Green
            return @{
                Version = $version
                Url = $asset.browser_download_url
                IsPrerelease = $false
            }
        }
    }
    catch {
        Write-Error ("Failed to fetch latest release info for {0}: {1}" -f $repo, $_.Exception.Message)
        return $null
    }
}

# Function to build script arguments with parameters
function Get-ScriptArguments {
    $argList = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    # Add parameters only if they are specified
    if ($RooVersion) { $argList += " -RooVersion `"$RooVersion`"" }
    if ($AiCoderToolsVersion) { $argList += " -AiCoderToolsVersion `"$AiCoderToolsVersion`"" }
    if ($OllamaModel) { $argList += " -OllamaModel `"$OllamaModel`"" }
    if ($RooUrl) { $argList += " -RooUrl `"$RooUrl`"" }
    if ($AiCoderToolsUrl) { $argList += " -AiCoderToolsUrl `"$AiCoderToolsUrl`"" }
    if ($forceInit) { $argList += " -forceInit" }
    if ($enableExperimentalTools) { $argList += " -enableExperimentalTools" }
    if ($preRelease) { $argList += " -preRelease" }
    return $argList
}

# Function to check and configure environment
function Initialize-Environment {
    # Check PowerShell version and administrator privileges
    $needsPs7 = $PSVersionTable.PSVersion.Major -lt 7
    $needsAdmin = -not (Test-Administrator)

    if ($needsPs7 -or $needsAdmin) {
        if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
            Write-Error "PowerShell 7 (pwsh) is not installed. Please install it from: https://aka.ms/powershell-release?tag=stable"
            Exit-Script 1
        }

        if ($needsPs7) {
            Write-Host "This script requires PowerShell 7 or later..." -ForegroundColor Yellow
        }
        if ($needsAdmin) {
            Write-Host "This script requires administrator privileges..." -ForegroundColor Yellow
        }

        $argList = Get-ScriptArguments
        Write-Host "→ Restarting with PowerShell 7$(if ($needsAdmin) {' as Administrator'})..." -ForegroundColor Gray
        Write-Verbose "Arguments: $argList"
        
        Start-Process pwsh -Verb RunAs -ArgumentList $argList -Wait
        exit
    }

    # Create temporary directory for downloads
    $script:tempDir = Join-Path $env:TEMP "AiCoderInstall"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    Write-Host "Using temporary directory: $tempDir"
    Push-Location $tempDir

    # Create prerelease marker file if preRelease is enabled
    if ($preRelease) {
        $rooUpdaterDir = Join-Path $env:TEMP "roo-updater"
        New-Item -ItemType Directory -Force -Path $rooUpdaterDir | Out-Null
        $prereleaseMarkerFile = Join-Path $rooUpdaterDir "prerelease-enabled"
        New-Item -ItemType File -Force -Path $prereleaseMarkerFile | Out-Null
        Write-Host "→ Created prerelease marker file at: $prereleaseMarkerFile" -ForegroundColor Gray
    }

    Write-Host "`n=== Environment Information ===" -ForegroundColor Cyan
    Write-Host "PowerShell Version : $($PSVersionTable.PSVersion)"
    Write-Host "Administrator Mode: $(Test-Administrator)"
}


# Function to install Ollama and its model
function Install-Ollama {
    Write-Host "`n=== Checking Ollama Installation ===" -ForegroundColor Cyan
    $ollamaExists = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollamaExists -and -not $forceInit) {
        Write-Host "✓ Ollama is already installed" -ForegroundColor Green
    } else {
        if ($ollamaExists) {
            Write-Host "→ Force reinstall requested" -ForegroundColor Yellow
        }
        Write-Host "→ Installing Ollama using winget..." -ForegroundColor Yellow
        try {
            # Check if winget is available
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                Write-Error "winget is not installed. Please install it from: https://aka.ms/getwinget"
                return $false
            }

            # Install Ollama using winget
            $process = Start-Process -FilePath "winget" -ArgumentList "install Ollama.Ollama --accept-source-agreements --accept-package-agreements" -PassThru -Wait
            $exitCode = $process.ExitCode
            
            if ($exitCode -eq 0) {
                Write-Host "✓ Ollama installed successfully" -ForegroundColor Green
                Write-Host "→ Refreshing environment variables to get the latest PATH..." -ForegroundColor Gray
                # Check if refreshenv is available (typically comes with Chocolatey)
                if (Get-Command refreshenv -ErrorAction SilentlyContinue) {
                    refreshenv
                } else {
                    # Alternative method to refresh only the PATH environment variable
                    Write-Host "→ 'refreshenv' command not found, updating PATH manually..." -ForegroundColor Gray
                    
                    # Update PATH specifically to ensure we get the latest
                    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
                    Write-Host "→ PATH environment variable refreshed" -ForegroundColor Gray
                }
                Write-Host "→ Waiting for Ollama service to initialize..." -ForegroundColor Gray
                Start-Sleep -Seconds 10
            } else {
                Write-Error "Failed to install Ollama using winget. Exit code: $exitCode"
                return $false
            }
        } catch {
            Write-Error "Failed to install Ollama: $_"
            return $false
        }
    }

    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    Write-Host "→ PATH environment variable refreshed" -ForegroundColor Gray

    # Install required model
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        Write-Host "`n=== Checking Ollama Model ===" -ForegroundColor Cyan
        Write-Host "→ Checking for model $OllamaModel..." -ForegroundColor Gray
        $modelExists = $false
        $existingModels = & ollama list 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Check if model name appears in the list output
            $modelExists = $existingModels -match $OllamaModel
        }
        
        if ($modelExists -and -not $forceInit) {
            Write-Host "✓ Model $OllamaModel is already installed" -ForegroundColor Green
        } else {
            if ($modelExists) {
                Write-Host "→ Force reinstall of model requested" -ForegroundColor Yellow
            }
            Write-Host "→ Installing model $OllamaModel..." -ForegroundColor Gray
            & ollama pull $OllamaModel
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Model installation completed" -ForegroundColor Green
            } else {
                Write-Error "Failed to install model $OllamaModel"
                return $false
            }
        }
        return $true
    } else {
        Write-Error "Ollama installation failed or not found. Please install manually from https://ollama.com/"
        return $false
    }
    return $true
}

# Function to install AI Coder Tools
function Install-AiCoderTools {
    Write-Host "`n=== Installing AI Coder Tools ===" -ForegroundColor Cyan
    
    # For prerelease versions, the file is still named without the "-preview" suffix
    $cleanVersion = $AiCoderToolsVersion -replace "-preview", ""
    $aiCoderZip = "ai-coder-tools-$cleanVersion.zip"
    $aiCoderDir = "ai-coder-tools-$cleanVersion"
    
    Write-Host "→ Using filename: $aiCoderZip" -ForegroundColor Gray
    
    # Always download from remote URL
    $downloadSuccess = Download-File -Url $AiCoderToolsUrl -OutFile $aiCoderZip -forceDownload $true

    if ($downloadSuccess) {
        Write-Host "→ Extracting files..." -ForegroundColor Gray
        try {
            Expand-Archive -Path $aiCoderZip -DestinationPath $aiCoderDir -Force
            $setupScript = Join-Path $aiCoderDir "setup.ps1"
            if (Test-Path $setupScript) {
                Write-Host "Running AI Coder Tools setup..."
                Write-Host "→ Executing setup script..." -ForegroundColor Gray
                
                # Execute with output capture for either case
                $setupOutput = if ($enableExperimentalTools) {
                    & pwsh -ExecutionPolicy Bypass -File $setupScript -enableExperimentalTools 2>&1
                }
                else {
                    & pwsh -ExecutionPolicy Bypass -File $setupScript 2>&1
                }
                
                # Display the setup script output
                $setupOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
                Write-Host "✓ Setup script execution completed" -ForegroundColor Green
                
                # Clean up extracted files
                Write-Host "→ Cleaning up extracted files..." -ForegroundColor Gray
                Remove-Item -Path $aiCoderDir -Recurse -Force
                Write-Host "✓ Cleanup completed" -ForegroundColor Green
                return $true
            }
            else {
                Write-Error "Setup script not found in extracted files"
                return $false
            }
        }
        catch {
            Write-Error "Failed to extract or run setup: $_"
            return $false
        }
    }
    return $false
}

# Function to set up GitHub Copilot for Claude 3.7
function Set-GithubCopilot--EnableClaude3-7 {
    Write-Host "`n=== Setting up GitHub Copilot for Claude 3.7 ===" -ForegroundColor Cyan
    try {
        # Find all GitHub Copilot Chat extension directories
        $extensionsPath = Join-Path $env:USERPROFILE ".vscode\extensions"
        $copilotChatDirs = Get-ChildItem -Path $extensionsPath -Directory | Where-Object { $_.Name -match "github.copilot-chat-" }
        
        if (-not $copilotChatDirs -or $copilotChatDirs.Count -eq 0) {
            Write-Host "→ GitHub Copilot Chat extension not found, skipping Claude 3.7 setup..." -ForegroundColor Yellow
            return $true
        }

        Write-Host "→ Found $($copilotChatDirs.Count) Copilot Chat extension(s)" -ForegroundColor Gray
        $successCount = 0
        $alreadySetupCount = 0
        
        # Process each extension
        foreach ($copilotChatDir in $copilotChatDirs) {
            Write-Host "→ Processing: $($copilotChatDir.Name)" -ForegroundColor Gray
            
            # Navigate to dist directory
            $distPath = Join-Path $copilotChatDir.FullName "dist"
            $extensionJsPath = Join-Path $distPath "extension.js"
            
            if (-not (Test-Path $extensionJsPath)) {
                Write-Host "→ extension.js not found in $distPath, skipping..." -ForegroundColor Yellow
                continue
            }

            # Read content
            $content = Get-Content -Path $extensionJsPath -Raw
            
            # Check if either pattern exists - matches content in backticks or quotes
            $pattern1 = ',"x-onbehalf-extension-id":`[^`]*`'
            $pattern2 = ',"x-onbehalf-extension-id":"[^"]*"'
            
            if ($content -match $pattern1 -or $content -match $pattern2) {
                # Create backup
                $backupPath = "$extensionJsPath.bak"
                Write-Host "→ Creating backup: $backupPath" -ForegroundColor Gray
                Copy-Item -Path $extensionJsPath -Destination $backupPath -Force

                # Modify content - remove both patterns
                $modifiedContent = $content -replace $pattern1, ''
                $modifiedContent = $modifiedContent -replace $pattern2, ''
                
                # Write modified content back
                Set-Content -Path $extensionJsPath -Value $modifiedContent
                Write-Host "✓ Successfully modified $($copilotChatDir.Name) to enable Claude 3.7" -ForegroundColor Green
                $successCount++
            } else {
                Write-Host "→ $($copilotChatDir.Name) is already set up for Claude 3.7" -ForegroundColor Green
                $alreadySetupCount++
            }
        }
        
        # Summary
        if ($successCount -gt 0 -or $alreadySetupCount -gt 0) {
            Write-Host "✓ Processed $($copilotChatDirs.Count) extension(s): $successCount modified, $alreadySetupCount already set up" -ForegroundColor Green
            return $true
        }
        
        return $true
    }
    catch {
        Write-Error "Failed to setup GitHub Copilot for Claude 3.7: $_"
        return $false
    }
}

# Functions for installing components
function Install-Components {
    # Install VSCode extension
    Write-Host "`n=== Installing Roo Cline Extension ===" -ForegroundColor Cyan
    
    # For prerelease versions, the file is still named without the "-preview" suffix
    # Strip any prerelease suffix from the version for the filename
    $cleanVersion = $RooVersion -replace "-preview", ""
    $rooVsix = "ms-roo-cline-$cleanVersion.vsix"
    
    Write-Host "→ Using filename: $rooVsix" -ForegroundColor Gray
    if (Download-File -Url $RooUrl -OutFile $rooVsix -forceDownload $true) {
        Write-Host "→ Installing extension..." -ForegroundColor Gray
        
        # Find VSCode installation path
        $vscodePath = $null
        $possiblePaths = @(
            # System-wide installation
            "${env:ProgramFiles}\Microsoft VS Code\bin\code.cmd",
            "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd",
            # User installation
            "${env:LOCALAPPDATA}\Programs\Microsoft VS Code\bin\code.cmd"
        )
        
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) {
                $vscodePath = $path
                break
            }
        }
        
        if ($vscodePath) {
            Write-Host "→ Found VSCode at: $vscodePath" -ForegroundColor Gray
            & "$vscodePath" --install-extension $rooVsix
        } else {
            Write-Host "→ VSCode path not found, attempting to use 'code' command..." -ForegroundColor Yellow
            & code --install-extension $rooVsix
        }
        
        Write-Host "✓ Extension installed successfully" -ForegroundColor Green
    }

    # Install Ollama and model if experimental tools are enabled
    if ($enableExperimentalTools) {
        if (-not (Install-Ollama)) {
            Write-Host "Failed to install Ollama and required model." -ForegroundColor Red
            Exit-Script 1
        }
    }
    else {
        Write-Host "→ Skipping Ollama installation (experimental tools not enabled)" -ForegroundColor Yellow
    }

    # Install AI Coder Tools
    if (-not (Install-AiCoderTools)) {
        Write-Host "Failed to install AI Coder Tools." -ForegroundColor Red
        Exit-Script 1
    }

    # Set up GitHub Copilot for Claude 3.7
    if (-not (Set-GithubCopilot--EnableClaude3-7)) {
        Write-Host "Failed to set up GitHub Copilot for Claude 3.7." -ForegroundColor Red
        Exit-Script 1
    }
}

# Initialize environment and check requirements
Initialize-Environment

# Ensure GitHub authentication is available
$isGitHubAuthed = Test-GitHubAuth
if (-not $isGitHubAuthed) {
    Write-Error "GitHub authentication is required to proceed with installation."
    Exit-Script 1
}

# Get latest release info if versions/URLs not provided
Write-Host "`n=== Checking Latest Versions ===" -ForegroundColor Cyan
if (-not $RooVersion -or -not $RooUrl) {
    $rooRelease = Get-LatestRelease -repo "ai-microsoft/Roo-Cline" -assetPattern "ms-roo-cline-*.vsix"
    if (-not $rooRelease) {
        Write-Error "Failed to get latest Roo Cline release info"
        Exit-Script 1
    }
    $RooVersion = $rooRelease.Version
    $RooUrl = $rooRelease.Url
}

if (-not $AiCoderToolsVersion -or -not $AiCoderToolsUrl) {
    $aiCoderRelease = Get-LatestRelease -repo "ai-microsoft/ai-coder-tools" -assetPattern "ai-coder-tools-*.zip"
    if (-not $aiCoderRelease) {
        Write-Error "Failed to get latest AI Coder Tools release info"
        Exit-Script 1
    }
    $AiCoderToolsVersion = $aiCoderRelease.Version
    $AiCoderToolsUrl = $aiCoderRelease.Url
}

Write-Host "`n=== Installation Versions ===" -ForegroundColor Cyan
# Display version info with prerelease status if available
if ($rooRelease -and $rooRelease.IsPrerelease) {
    Write-Host "Roo Cline       : v$RooVersion (prerelease)" -ForegroundColor Gray
} else {
    Write-Host "Roo Cline       : v$RooVersion" -ForegroundColor Gray
}

if ($aiCoderRelease -and $aiCoderRelease.IsPrerelease) {
    Write-Host "AI Coder Tools : v$AiCoderToolsVersion (prerelease)" -ForegroundColor Gray
} else {
    Write-Host "AI Coder Tools : v$AiCoderToolsVersion" -ForegroundColor Gray
}

# Install all components
Install-Components

# Cleanup
Pop-Location
Write-Host "`n=== Installation Complete ===" -ForegroundColor Cyan
Write-Host "✓ All components have been installed successfully" -ForegroundColor Green

# Keep the window open if running as administrator
if (Test-Administrator) {
    Write-Host "→ Please restart your visual studio code to apply changes." -ForegroundColor Yellow
    Write-Host "`nPress any key to exit..." -ForegroundColor Yellow -NoNewline
    $null = $Host.UI.RawUI.ReadKey()
}
