# Set the path to the folder you want to clean up
$folderPath = "C:\Path\To\Folder"

# Set the number of days to keep files
$daysToKeep = 30

# Get the current date
$currentDate = Get-Date

# Get the files older than $daysToKeep days
$oldFiles = Get-ChildItem -Path $folderPath -Recurse -File | Where-Object {$_.LastWriteTime -lt $currentDate.AddDays(-$daysToKeep)}

# Compress the old files
$oldFiles | ForEach-Object {
    $fileName = $_.FullName
    $zipFileName = $fileName + ".zip"
    Write-Host "Compressing $fileName to $zipFileName"
    Compress-Archive -Path $fileName -DestinationPath $zipFileName -Force
}

# Delete the original files
$oldFiles | Remove-Item -Force

# Delete the compressed files older than $daysToKeep days
$oldZipFiles = Get-ChildItem -Path $folderPath -Recurse -File | Where-Object {$_.LastWriteTime -lt $currentDate.AddDays(-$daysToKeep) -and $_.Extension -eq ".zip"}
$oldZipFiles | Remove-Item -Force
