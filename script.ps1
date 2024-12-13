# Clear the docs.md file first
Clear-Content -Path "docs.md" -ErrorAction SilentlyContinue

# Create the docs.md file if it doesn't exist
if (-not (Test-Path "docs.md")) {
    New-Item -Path "docs.md" -ItemType File
}

# Get all markdown files in the guide directory
$markdownFiles = Get-ChildItem -Path "guide\*.md"

# Loop through each markdown file
foreach ($file in $markdownFiles) {
    # Add a separator line
    Add-Content -Path "docs.md" -Value "`n---`n"
    
    # Add the filename as a header
    Add-Content -Path "docs.md" -Value "# $($file.BaseName)`n"
    
    # Append the contents of the file
    Get-Content -Path $file.FullName | Add-Content -Path "docs.md"
}

Write-Host "Documentation has been concatenated into docs.md"