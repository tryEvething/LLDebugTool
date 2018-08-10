//
//  LLStorageManager.m
//
//  Copyright (c) 2018 LLDebugTool Software Foundation (https://github.com/HDB-Li/LLDebugTool)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

#import "LLStorageManager.h"
#import <FMDB/FMDB.h>
#import "NSString+LL_Utils.h"
#import "LLNetworkModel.h"
#import "LLCrashModel.h"
#import "LLAppHelper.h"
#import "LLLogModel.h"
#import "LLTool.h"
#import "LLDebugToolMacros.h"
#import "LLLogHelperEventDefine.h"

static LLStorageManager *_instance = nil;

// Table SQL
static NSString *const kCreateCrashModelTableSQL = @"CREATE TABLE IF NOT EXISTS CrashModelTable(ObjectData BLOB NOT NULL,LaunchDate TEXT NOT NULL);";
static NSString *const kCreateLogModelTableSQL = @"CREATE TABLE IF NOT EXISTS LogModelTable(ObjectData BLOB NOT NULL,Identity TEXT NOT NULL,LaunchDate TEXT NOT NULL);";
static NSString *const kCreateNetworkModelTableSQL = @"CREATE TABLE IF NOT EXISTS NetworkModelTable(ObjectData BLOB NOT NULL,Identity TEXT NOT NULL,LaunchDate TEXT NOT NULL);";

// Table Name
static NSString *const kCrashModelTable = @"CrashModelTable";
static NSString *const kLogModelTable = @"LogModelTable";
static NSString *const kNetworkModelLabel = @"NetworkModelTable";

// Column Name
static NSString *const kObjectDataColumn = @"ObjectData";
static NSString *const kIdentityColumn = @"Identity";
static NSString *const kLaunchDateColumn = @"launchDate";

@interface LLStorageManager ()

@property (strong , nonatomic) FMDatabaseQueue * dbQueue;

/**
 * Array to cache crash models.
 */
@property (strong , nonatomic) NSArray *cacheCrashModels;

@property (copy , nonatomic) NSString *folderPath;

@property (copy , nonatomic) NSString *screenshotFolderPath;

@end

@implementation LLStorageManager

+ (instancetype)sharedManager {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[LLStorageManager alloc] init];
        [_instance initial];
    });
    return _instance;
}

#pragma mark - Crash Model
- (BOOL)saveCrashModel:(LLCrashModel *)model {
    if ([NSThread currentThread] == [NSThread mainThread]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self saveCrashModel:model];
        });
        return YES;
    }
    NSString *launchDate = [[LLAppHelper sharedHelper] launchDate];
    if (launchDate.length == 0) {
        [self log:@"Save crash model fail, because launchDate is null"];
        return NO;
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:model];
    if (data.length == 0) {
        [self log:@"Save crash model fail, because model's data is null"];
        return NO;
    }
    __block NSArray *arguments = @[data,launchDate];
    __block BOOL ret = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"INSERT INTO %@(%@,%@) VALUES (?,?);",kCrashModelTable,kObjectDataColumn,kLaunchDateColumn] values:arguments error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Save crash model fail,Error = %@",error.localizedDescription]];
        } else {
            [self log:@"Save crash success!"];
        }
    }];
    return ret;
}

- (BOOL)removeCrashModels:(NSArray <LLCrashModel *>*)models{
    BOOL ret = YES;
    for (LLCrashModel *model in models) {
        ret = ret && [self _removeCrashModel:model];
    }
    return ret;
}

- (NSArray <LLCrashModel *>*)getAllCrashModel {
    if (_cacheCrashModels == nil) {
        __block NSMutableArray *modelArray = [[NSMutableArray alloc] init];
        [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            FMResultSet *set = [db executeQuery:[NSString stringWithFormat:@"SELECT * FROM %@",kCrashModelTable]];
            while ([set next]) {
                NSData *objectData = [set dataForColumn:kObjectDataColumn];
                LLCrashModel *model = [NSKeyedUnarchiver unarchiveObjectWithData:objectData];
                if (model) {
                    [modelArray insertObject:model atIndex:0];
                }
            }
        }];
        _cacheCrashModels = modelArray;
    }
    return _cacheCrashModels;
}

- (BOOL)_removeCrashModel:(LLCrashModel *)model {
    __block BOOL ret = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = ?",kCrashModelTable,kLaunchDateColumn] values:@[model.launchDate] error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Delete crash model fail,error = %@",error]];
        }
    }];
    if (ret) {
        _cacheCrashModels = nil;
    }
    return ret;
}

#pragma mark - Network Model
- (BOOL)saveNetworkModel:(LLNetworkModel *)model {
    if ([NSThread currentThread] == [NSThread mainThread]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self saveNetworkModel:model];
        });
        return YES;
    }
    NSString *launchDate = [[LLAppHelper sharedHelper] launchDate];
    if (launchDate.length == 0) {
        return NO;
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:model];
    if (data.length == 0) {
        [self log:@"Save network model fail, because model's data is null"];
        return NO;
    }
    
    __block NSArray *arguments = @[data,launchDate,model.identity];
    __block BOOL ret = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"INSERT INTO %@(%@,%@,%@) VALUES (?,?,?);",kNetworkModelLabel,kObjectDataColumn,kLaunchDateColumn,kIdentityColumn] values:arguments error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Save network model fail,Error = %@",error.localizedDescription]];
        }
    }];
    return ret;
}

- (NSArray <LLNetworkModel *>*)getAllNetworkModels {
    NSString *launchDate = [[LLAppHelper sharedHelper] launchDate];
    return [self getAllNetworkModelsWithLaunchDate:launchDate];
}

- (NSArray <LLNetworkModel *>*)getAllNetworkModelsWithLaunchDate:(NSString *)launchDate {
    if (launchDate.length == 0) {
        return @[];
    }
    
    __block NSMutableArray *modelArray = [[NSMutableArray alloc] init];
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        FMResultSet *set = [db executeQuery:[NSString stringWithFormat:@"SELECT * FROM %@ WHERE %@ = ?",kNetworkModelLabel,kLaunchDateColumn] values:@[launchDate] error:&error];
        while ([set next]) {
            NSData *data = [set objectForColumn:kObjectDataColumn];
            LLNetworkModel *model = [NSKeyedUnarchiver unarchiveObjectWithData:data];
            if (model) {
                [modelArray insertObject:model atIndex:0];
            }
        }
    }];
    return modelArray;
}

- (BOOL)removeNetworkModels:(NSArray <LLNetworkModel *>*)models {
    BOOL ret = YES;
    for (LLNetworkModel *model in models) {
        ret = ret && [self _removeNetworkModel:model];
    }
    return ret;
}

- (BOOL)_removeNetworkModel:(LLNetworkModel *)model {
    __block BOOL ret = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = ?",kNetworkModelLabel,kIdentityColumn] values:@[model.identity] error:&error];
        if (!ret) {
            [self log:@"Delete networkModel fail"];
        }
    }];
    return ret;
}

#pragma mark - Log Model
- (BOOL)saveLogModel:(LLLogModel *)model {
    if ([NSThread currentThread] == [NSThread mainThread]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self saveLogModel:model];
        });
        return YES;
    }
    NSString *launchDate = [[LLAppHelper sharedHelper] launchDate];
    if (model.message.length == 0 || launchDate.length == 0) {
        return NO;
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:model];
    if (data.length == 0) {
        [self log:@"Save log model fail, because model's data is null"];
        return NO;
    }
    __block NSArray *arguments = @[data,launchDate,model.identity];
    __block BOOL ret = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"INSERT INTO %@(%@,%@,%@) VALUES (?,?,?);",kLogModelTable,kObjectDataColumn,kLaunchDateColumn,kIdentityColumn] values:arguments error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Save log model fail,Error = %@",error.localizedDescription]];
        }
    }];
    return ret;
}

- (NSArray <LLLogModel *>*)getAllLogModels {
    NSString *launchDate = [[LLAppHelper sharedHelper] launchDate];
    return [self getAllLogModelsWithLaunchDate:launchDate];
}

- (NSArray <LLLogModel *>*)getAllLogModelsWithLaunchDate:(NSString *)launchDate {
    if (launchDate.length == 0) {
        return @[];
    }
    
    __block NSMutableArray *modelArray = [[NSMutableArray alloc] init];
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        FMResultSet *set = [db executeQuery:[NSString stringWithFormat:@"SELECT * FROM %@ WHERE %@ = ?",kLogModelTable,kLaunchDateColumn] values:@[launchDate] error:&error];
        while ([set next]) {
            NSData *data = [set objectForColumn:kObjectDataColumn];
            LLLogModel *model = [NSKeyedUnarchiver unarchiveObjectWithData:data];
            if (model) {
                [modelArray insertObject:model atIndex:0];
            }
        }
    }];
    return modelArray;
}

- (BOOL)removeLogModels:(NSArray <LLLogModel *>*)models {
    BOOL ret = YES;
    for (LLLogModel *model in models) {
        ret = ret && [self _removeLogModel:model];
    }
    return ret;
}

- (BOOL)_removeLogModel:(LLLogModel *)model {
    __block BOOL ret = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = ?",kLogModelTable,kIdentityColumn] values:@[model.identity] error:&error];
        if (!ret) {
            [self log:@"Delete logModel fail"];
        }
    }];
    return ret;
}

#pragma mark - Screenshot
- (BOOL)saveScreenshot:(UIImage *)image name:(NSString *)name {
    if ([NSThread currentThread] == [NSThread mainThread]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self saveScreenshot:image name:name];
        });
        return YES;
    }
    if (name.length == 0) {
        name = [LLTool staticStringFromDate:[NSDate date]];
    }
    name = [name stringByAppendingPathExtension:@"png"];
    NSString *path = [self.screenshotFolderPath stringByAppendingPathComponent:name];
    return [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
}

#pragma mark - Primary
/**
 Initialize something
 */
- (void)initial {
    __unused BOOL result = [self initDatabase];
    NSAssert(result, @"Init Database fail");
    [self reloadLogModelTable];
}

/**
 Init database.
 */
- (BOOL)initDatabase {
    self.folderPath = [LLConfig sharedConfig].folderPath;
    [LLTool createDirectoryAtPath:self.folderPath];
    
    self.screenshotFolderPath = [self.folderPath stringByAppendingPathComponent:@"Screenshot"];
    [LLTool createDirectoryAtPath:self.screenshotFolderPath];
    
    NSString *filePath = [self.folderPath stringByAppendingPathComponent:@"LLDebugTool.db"];
    
    _dbQueue = [FMDatabaseQueue databaseQueueWithPath:filePath];
    
    __block BOOL ret1 = NO;
    __block BOOL ret2 = NO;
    __block BOOL ret3 = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        // ObjectData use to convert to LLCrashModel, launchDate use as identity
        ret1 = [db executeUpdate:kCreateCrashModelTableSQL];
        if (!ret1) {
            [self log:@"Create CrashModelTable fail"];
        }
        
        // ObjectData use to convert to LLLogModel, launchDate use to find LLCrashModel, Identity use as identity
        ret2 = [db executeUpdate:kCreateLogModelTableSQL];
        if (!ret2) {
            [self log:@"Create LogModelTable fail"];
        }
        
        // ObjectData use to convert to LLNetworkModel, launchDate use to find LLCrashModel, Identity use as identity
        ret3 = [db executeUpdate:kCreateNetworkModelTableSQL];
        if (!ret3) {
            [self log:@"Create NetworkModelTable fail"];
        }
    }];
    return ret1 && ret2 && ret3;
}

/**
 * Remove unused log models and networks models.
 */
- (void)reloadLogModelTable {
    NSArray *crashModels = [self getAllCrashModel];
    NSMutableArray *launchDates = [[NSMutableArray alloc] init];
    for (LLCrashModel *model in crashModels) {
        if (model.launchDate.length) {
            [launchDates addObject:model.launchDate];
        }
    }
    // Need to remove logs in a global queue.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self removeLogModelAndNetworkModelNotIn:launchDates];
    });
}

- (BOOL)removeLogModelAndNetworkModelNotIn:(NSArray *)launchDates {
    
    __block NSMutableString *launchString = [[NSMutableString alloc] init];
    [launchString appendString:@"("];
    for (int i = 0; i < launchDates.count; i++) {
        NSString *launchDate = launchDates[i];
        [launchString appendFormat:@"'%@', ",launchDate];
    }
    [launchString appendFormat:@"'%@'",[LLAppHelper sharedHelper].launchDate];
    [launchString appendString:@")"];
    
    __block BOOL ret = NO;
    __block BOOL ret2 = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ NOT IN %@;",kLogModelTable,kLaunchDateColumn,launchDates] values:nil error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Remove launch log fail, error = %@",error]];
        }
        
        ret2 = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ NOT IN %@;",kNetworkModelLabel,kLaunchDateColumn,launchDates] values:nil error:&error];
        if (!ret2) {
            [self log:[NSString stringWithFormat:@"Remove launch network fail, error = %@",error]];
        }
    }];
    return ret && ret2;
}

- (void)log:(NSString *)message {
    LLog_Alert_Event(kLLLogHelperDebugToolEvent, message);
}

@end
