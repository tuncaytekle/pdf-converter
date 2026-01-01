#!/bin/bash
set -e

BASE="pdf-converter"

# Create directory structure
mkdir -p "$BASE/App"
mkdir -p "$BASE/CloudSync"
mkdir -p "$BASE/Files"
mkdir -p "$BASE/Scan"
mkdir -p "$BASE/Account"
mkdir -p "$BASE/Onboarding"
mkdir -p "$BASE/PDF"
mkdir -p "$BASE/Coordinators"
mkdir -p "$BASE/Models"
mkdir -p "$BASE/Services"
mkdir -p "$BASE/Analytics"
mkdir -p "$BASE/Shared/ViewModels"
mkdir -p "$BASE/Shared/Helpers"

echo "✅ Created directory structure"

# App
git mv "$BASE/PDFConverterApp.swift" "$BASE/App/"
git mv "$BASE/Persistence.swift" "$BASE/App/"

# CloudSync
git mv "$BASE/CloudBackupManager.swift" "$BASE/CloudSync/"
git mv "$BASE/CloudSyncBanner.swift" "$BASE/CloudSync/"
git mv "$BASE/CloudSyncStatus.swift" "$BASE/CloudSync/"

# Files
git mv "$BASE/FilesView.swift" "$BASE/Files/"
git mv "$BASE/FileManagementService.swift" "$BASE/Files/"
git mv "$BASE/FileContentIndexer.swift" "$BASE/Files/"
git mv "$BASE/PDFStorage.swift" "$BASE/Files/"
git mv "$BASE/FileOperationsViewModel.swift" "$BASE/Files/"

# Scan
git mv "$BASE/ScanFlowCoordinator.swift" "$BASE/Scan/"
git mv "$BASE/DocumentScannerView.swift" "$BASE/Scan/"
git mv "$BASE/PhotoPickerView.swift" "$BASE/Scan/"
git mv "$BASE/ScanReviewViewModel.swift" "$BASE/Scan/"
git mv "$BASE/ScanWorkflowError.swift" "$BASE/Scan/"

# Account
git mv "$BASE/AccountView.swift" "$BASE/Account/"
git mv "$BASE/AccountViewModel.swift" "$BASE/Account/"
git mv "$BASE/SubscriptionManager.swift" "$BASE/Account/"
git mv "$BASE/SubscriptionGate.swift" "$BASE/Account/"
git mv "$BASE/PaywallView.swift" "$BASE/Account/"
git mv "$BASE/PaywallViewModel.swift" "$BASE/Account/"

# Onboarding
git mv "$BASE/OnboardingFlowView.swift" "$BASE/Onboarding/"
git mv "$BASE/OnboardingHelpers.swift" "$BASE/Onboarding/"
git mv "$BASE/OnboardingViewModel.swift" "$BASE/Onboarding/"

# PDF
git mv "$BASE/PDFGenerator.swift" "$BASE/PDF/"
git mv "$BASE/PDFThumbnailGenerator.swift" "$BASE/PDF/"
git mv "$BASE/PDFViewHelpers.swift" "$BASE/PDF/"
git mv "$BASE/PDFEditingViewModel.swift" "$BASE/PDF/"

# Coordinators
git mv "$BASE/AppCoordinator.swift" "$BASE/Coordinators/"

# Models
git mv "$BASE/SupportingTypes.swift" "$BASE/Models/"
git mv "$BASE/CommonEnums.swift" "$BASE/Models/"

# Services
git mv "$BASE/GotenbergClient.swift" "$BASE/Services/"
git mv "$BASE/BiometricAuthentication.swift" "$BASE/Services/"
git mv "$BASE/SignatureManagement.swift" "$BASE/Services/"

# Analytics
git mv "$BASE/AnalyticsKey.swift" "$BASE/Analytics/"
git mv "$BASE/AnalyticsTracking.swift" "$BASE/Analytics/"
git mv "$BASE/AnonymousIdProvider.swift" "$BASE/Analytics/"
git mv "$BASE/PostHogTracker.swift" "$BASE/Analytics/"

# Shared ViewModels
git mv "$BASE/TabNavigationViewModel.swift" "$BASE/Shared/ViewModels/"
git mv "$BASE/ToolsViewModel.swift" "$BASE/Shared/ViewModels/"
git mv "$BASE/ConversionViewModel.swift" "$BASE/Shared/ViewModels/"

# Shared Helpers
git mv "$BASE/CommonHelpers.swift" "$BASE/Shared/Helpers/"
git mv "$BASE/SizingHelpers.swift" "$BASE/Shared/Helpers/"
git mv "$BASE/ToolCards.swift" "$BASE/Shared/Helpers/"

echo "✅ All files moved with git mv"
echo ""
echo "📋 Directory structure:"
tree -d -L 2 "$BASE" 2>/dev/null || find "$BASE" -type d -not -path '*/\.*' | head -30
